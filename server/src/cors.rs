use axum::body::Body;
use axum::extract::Request;
use axum::http::{HeaderValue, Method, StatusCode};
use axum::middleware::Next;
use axum::response::Response;

/// Lets the browser client (`flutter run -d chrome`) talk to the API. A browser sends an
/// OPTIONS preflight before a JSON POST and blocks the answer without Access-Control headers,
/// so the preflight is answered here rather than by a route: the routes serve the methods the
/// API documents, and OPTIONS belongs to the transport.
///
/// The Origin is reflected instead of wildcarded: that is safer (a wildcard grants every site
/// access) and it is what a browser accepts when credentials are involved. `Vary: Origin` keeps
/// caches correct when different origins reflect different answers.
pub async fn middleware(req: Request, next: Next) -> Response {
    let origin = req
        .headers()
        .get("origin")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_string();

    let mut response = if req.method() == Method::OPTIONS {
        preflight()
    } else {
        next.run(req).await
    };

    // `X-Content-Type-Options` belongs on every answer from this server. The JSON, file and
    // redirect answers carry it from `respond`; this layer is what covers the ones the router
    // answers without a handler — a wrong method and a path no endpoint owns — and the
    // preflight, which is answered here.
    response
        .headers_mut()
        .insert("x-content-type-options", HeaderValue::from_static("nosniff"));

    if origin.is_empty() {
        // A client that is not a browser sends no Origin; then nothing belongs on the answer,
        // and the endpoint still works.
        return response;
    }

    let headers = response.headers_mut();
    // An Origin a header value cannot hold is not a browser request; answer without CORS.
    if let Ok(value) = HeaderValue::from_str(&origin) {
        headers.insert("access-control-allow-origin", value);
        headers.append("vary", HeaderValue::from_static("Origin"));
    }

    response
}

/// The permission to send the real request: no body, no content type. The methods are the ones
/// the API serves, and DELETE is one of them — it is not a simple method, so a browser asks
/// first and a list without it blocks every delete the client makes.
fn preflight() -> Response {
    Response::builder()
        .status(StatusCode::NO_CONTENT)
        .header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
        .header("access-control-allow-headers", "Content-Type, Authorization")
        .header("access-control-max-age", "600")
        .body(Body::empty())
        .expect("a response with only a status and known header names")
}
