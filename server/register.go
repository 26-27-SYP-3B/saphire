package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"math"
	"net"
	"net/http"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"golang.org/x/crypto/bcrypt"
)

// ErrUsernameTaken means the username is already registered.
var ErrUsernameTaken = errors.New("username already taken")

// isUniqueConstraintError detects the SQLite UNIQUE violation without
// importing the driver package.
func isUniqueConstraintError(err error) bool {
	return strings.Contains(err.Error(), "UNIQUE constraint failed")
}

// Validation limits. Password max is 72 bytes because bcrypt silently
// truncates longer input, so we reject it instead of hashing a truncated value.
const (
	minUsernameLen = 3
	maxUsernameLen = 32
	minPasswordLen = 8
	maxPasswordLen = 72
	maxBodyBytes   = 4 << 10 // 4 KiB is plenty for username + password JSON

	bcryptCost = 12
)

var usernamePattern = regexp.MustCompile(`^[a-z0-9_.-]+$`)

// RegistrationRequest is the JSON body of POST /api/register.
type RegistrationRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// normalizeUsername trims and lowercases the username so "Lukas" and "lukas"
// are the same account.
func normalizeUsername(name string) string {
	return strings.ToLower(strings.TrimSpace(name))
}

// validateRegistration returns an error describing the first problem with the
// input, or nil if it is acceptable.
func validateRegistration(req *RegistrationRequest) error {
	if n := utf8.RuneCountInString(req.Username); n < minUsernameLen || n > maxUsernameLen {
		return errors.New("username must be 3-32 characters")
	}
	if !usernamePattern.MatchString(req.Username) {
		return errors.New("username may only contain letters, digits, underscore, dot and hyphen")
	}
	if len(req.Password) < minPasswordLen {
		return errors.New("password must be at least 8 characters")
	}
	if len(req.Password) > maxPasswordLen {
		return errors.New("password must be at most 72 characters")
	}
	// Control characters (including NUL) are not valid password input.
	for _, r := range req.Password {
		if r < 0x20 || r == 0x7f {
			return errors.New("password must not contain control characters")
		}
	}
	return nil
}

// rateLimiter is a per-IP token bucket that protects the registration
// endpoint from brute-force abuse.
type rateLimiter struct {
	mu       sync.Mutex
	buckets  map[netip.Addr]*tokenBucket
	capacity int
	refill   time.Duration
}

type tokenBucket struct {
	tokens float64
	last   time.Time
}

func newRateLimiter(capacity int, refill time.Duration) *rateLimiter {
	return &rateLimiter{buckets: make(map[netip.Addr]*tokenBucket), capacity: capacity, refill: refill}
}

// allow reports whether a request from ip fits in the bucket. When it does not,
// the second value is the seconds until the next token refills, so a handler can
// answer with an honest Retry-After instead of a fixed guess that overstates the
// wait. A bucket that has been idle long enough to be fully refilled is
// equivalent to a fresh one, so stale entries are pruned to keep the map bounded
// to IPs that are actually active.
func (l *rateLimiter) allow(ip netip.Addr) (bool, int) {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := time.Now()
	b := l.buckets[ip]
	if b == nil {
		l.prune(now)
		b = &tokenBucket{tokens: float64(l.capacity), last: now}
		l.buckets[ip] = b
	}

	b.tokens += now.Sub(b.last).Seconds() / l.refill.Seconds()
	if b.tokens > float64(l.capacity) {
		b.tokens = float64(l.capacity)
	}
	b.last = now

	if b.tokens < 1 {
		return false, int(math.Ceil((1.0 - b.tokens) * l.refill.Seconds()))
	}
	b.tokens--
	return true, 0
}

func (l *rateLimiter) prune(now time.Time) {
	idle := time.Duration(l.capacity) * l.refill
	for ip, b := range l.buckets {
		if now.Sub(b.last) >= idle {
			delete(l.buckets, ip)
		}
	}
}

// clientIP extracts the peer address, optionally trusting X-Forwarded-For
// when running behind a reverse proxy.
func clientIP(r *http.Request) netip.Addr {
	if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
		if addr, err := netip.ParseAddr(strings.TrimSpace(strings.Split(fwd, ",")[0])); err == nil {
			return addr
		}
	}
	// RemoteAddr is "ip:port", and for IPv6 the address is bracketed, so
	// split the port off properly instead of cutting at the last colon.
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	addr, err := netip.ParseAddr(strings.Trim(host, "[]"))
	if err != nil {
		return netip.Addr{} // unknown peer, share one bucket
	}
	return addr
}

// registerHandler answers POST /api/register with {"username": ..., "password": ...}.
// This is the trust boundary: the client form only checks the fields roughly, here
// the values become valid or the request is rejected. The password is stored only
// as a bcrypt hash and never returned.
func registerHandler(db *sql.DB, limiter *rateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ip := clientIP(r)
		if ok, retry := limiter.allow(ip); !ok {
			w.Header().Set("Retry-After", strconv.Itoa(retry))
			writeError(w, http.StatusTooManyRequests, "too many registrations from this address, try again later")
			return
		}

		// Strict request size limit and strict JSON parsing.
		r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
		dec := json.NewDecoder(r.Body)
		dec.DisallowUnknownFields()

		var req RegistrationRequest
		if err := dec.Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "body must be one JSON object with \"username\" and \"password\"")
			return
		}
		if dec.More() {
			writeError(w, http.StatusBadRequest, "body must contain exactly one JSON object")
			return
		}

		req.Username = normalizeUsername(req.Username)
		if err := validateRegistration(&req); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}

		// Hash before checking existence so the response time does not reveal
		// whether the username exists. Never store or return the plain password.
		hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcryptCost)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "could not hash password")
			return
		}

		user := &User{Username: req.Username, PasswordHash: string(hash)}
		if err := user.Insert(db); err != nil {
			if errors.Is(err, ErrUsernameTaken) {
				writeError(w, http.StatusConflict, "username is not available")
				return
			}
			writeError(w, http.StatusInternalServerError, "could not save user")
			return
		}

		writeJSON(w, http.StatusCreated, user) // PasswordHash has json:"-", so it is not sent
	}
}
