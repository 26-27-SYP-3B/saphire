import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/storage/session_store.dart';
import '../../../shared/widgets/saphire_logo.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/user.dart';
import '../../library/data/library_repository.dart';
import '../../library/domain/library_entry.dart';
import '../../player/data/queue_repository.dart';
import '../../player/domain/player.dart';
import '../../player/domain/queue.dart';
import '../../player/presentation/queue_panel.dart';
import '../../playlists/data/playlist_repository.dart';
import '../../upload/data/upload_repository.dart';
import '../../upload/domain/track.dart';

/// A picked song: the name the server would store as the title and its bytes.
typedef PickedAudio = ({String name, Uint8List bytes});
typedef PickAudio = Future<List<PickedAudio>?> Function();

/// One file in the upload window: what it is, how far it got, what the server
/// said about it. Every picked file keeps its own row, so the results do not mix.
class _UploadFile {
  _UploadFile(this.name);

  final String name;
  int percent = 0;
  String? error;
  Track? track;
}

/// The picker used when the screen is started without one. A widget test passes
/// its own, because the plugin cannot answer there. Any file can be picked,
/// because which formats are allowed is the server's decision (see server/music.go);
/// a file it refuses comes back as its message and is shown on that file's row.
Future<List<PickedAudio>?> pickAudioFiles() async {
  final picked = await FilePicker.pickFiles(type: FileType.any);
  if (picked.isEmpty) return null;

  // shortcut: the whole file is held in memory. Upgrade: stream from the path on
  // the platforms that give one, so a 500 MiB song is not read twice.
  return [for (final file in picked) (name: file.name, bytes: await file.readAsBytes())];
}

/// The greeting follows the time of day.
String greetingFor(DateTime now) {
  if (now.hour < 11) return 'Guten Morgen';
  if (now.hour < 18) return 'Guten Nachmittag';
  return 'Guten Abend';
}

/// What the page shows. The uploaded songs are real; the playlist rows are placeholder,
/// because they would need the real playlists from GET /api/playlists, and this page does
/// not load them — the Playlists page is where a playlist exists. The only real songs on
/// this page are the search results, which come from GET /api/music.
const _placeholders = [
  (title: 'Lieblingssongs', meta: 'Playlist · 150 Songs', icon: Icons.favorite),
  (title: 'Workout', meta: 'Playlist · 87 Songs', icon: Icons.local_activity),
  (title: 'Chill Vibes', meta: 'Playlist · 122 Songs', icon: Icons.wb_sunny),
  (title: 'Techno', meta: 'Playlist · 95 Songs', icon: Icons.graphic_eq),
  (title: 'Good Times', meta: 'Playlist · 78 Songs', icon: Icons.west),
];

const _navItems = [
  (label: 'Home', icon: Icons.home, selected: true, route: ''),
  (label: 'Suche', icon: Icons.search, selected: false, route: ''),
  (label: 'Bibliothek', icon: Icons.library_books, selected: false, route: ''),
  // Playlists and the queue are the two areas that have endpoints now, so they can be
  // opened. The others stay labels.
  (label: 'Playlists', icon: Icons.playlist_play, selected: false, route: '/playlists'),
  (label: 'Warteschlange', icon: Icons.queue_music, selected: false, route: '/queue'),
];

/// What the server accepts (server/music.go): the client only says it up front,
/// the upload itself is still checked on the server.
const _uploadHint = 'Erlaubt: MP3, WAV, M4A, OGG, OPUS, FLAC, AAC · höchstens 500 MiB pro Datei';

/// The home screen: the app on the left, the greeting and the rows on the right.
/// Upload, playlists and the queue reach the server; the playlist rows below are the
/// placeholders from the mock, because there is no data behind them until a playlist is
/// opened on the Playlists page.
///
/// The search field is the one place this page shows real songs: the server has no search
/// endpoint, so the page reads the library once and filters what it got. The bar at the
/// bottom shows what the shared player is playing — this page does not own a player, it
/// only puts a song into the queue the player reads.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.repository,
    required this.uploads,
    required this.library,
    required this.queues,
    required this.playlists,
    required this.player,
    required this.session,
    this.pickAudio = pickAudioFiles,
  });

  final AuthRepository repository;
  final UploadRepository uploads;
  final LibraryRepository library;
  final QueueRepository queues;
  final PlaylistRepository playlists;
  final QueuePlayer player;
  final SessionStore session;
  final PickAudio pickAudio;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<_UploadFile> _files = [];
  List<LibraryEntry> _library = [];
  final TextEditingController _search = TextEditingController();

  // The message from the session check. What a single file got is on its own row.
  String? _note;
  User? _user;
  // While the picker is open a second tap must not open it again.
  bool _picking = false;
  // While a queue call is running the same tap must not start it again.
  bool _busy = false;
  // The queue is opened from the player bar. On a desktop it is the panel on the right and
  // this page stays; on a phone the panel takes the page. Opening it never touches the
  // player, so the song that is running keeps running.
  bool _queueOpen = false;
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    // The player moves on its own when a song ends. Without a listener the bar would keep
    // showing the song that just finished.
    _changes = widget.player.changes.listen((_) {
      if (mounted) setState(() {});
    });
    // The name in the greeting is the account name, so it comes from the session
    // check: the session store holds only the token, nothing that says who we are.
    _loadUser();
    // The search has nothing to filter until the library is here, so it is read once
    // when the page opens rather than on every keystroke.
    _loadLibrary();
  }

  @override
  void dispose() {
    // The player belongs to the whole app, so only this page's listener is dropped here.
    _changes?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    try {
      final user = await widget.repository.currentSession();
      if (mounted) setState(() => _user = user);
    } on AuthException catch (error) {
      if (!mounted) return;
      // The server just said this token is gone, so the app must not keep it:
      // the router guard and the page then agree on the same session.
      widget.repository.logout();
      setState(() => _note = error.message);
    }
  }

  Future<void> _loadLibrary() async {
    try {
      final library = await widget.library.list();
      if (!mounted) return;
      setState(() => _library = library);
    } on LibraryException catch (error) {
      if (mounted) setState(() => _note = error.message);
    }
  }

  Future<void> _upload() async {
    if (_picking) return;

    setState(() => _picking = true);
    final List<PickedAudio>? picked;
    try {
      picked = await widget.pickAudio();
    } finally {
      if (mounted) setState(() => _picking = false);
    }
    if (picked == null) return;

    for (final file in picked) {
      final row = _UploadFile(file.name);
      // The screen can be gone by the time the next file of a batch is answered.
      if (!mounted) return;
      setState(() => _files.add(row));

      try {
        final track = await widget.uploads.upload(
          filename: file.name,
          bytes: file.bytes,
          // The percent is what Dio reports while this file is written; the server
          // answers after it has read and checked it.
          onProgress: (sent, total) {
            if (mounted && total > 0) setState(() => row.percent = (sent * 100 / total).round());
          },
        );
        if (mounted) setState(() => row.track = track);
      } on UploadException catch (error) {
        if (mounted) setState(() => row.error = error.message);
      }
    }
  }

  /// The name the row shows: before the answer the picked name, after it the title
  /// the server stored (base name only, see api-docs.md).
  String _title(_UploadFile file) => file.track?.title ?? file.name;

  /// What a row says about its own file: the progress, or what the server answered.
  String _result(_UploadFile file) {
    if (file.error != null) return file.error!;
    if (file.track == null) return 'wird hochgeladen · ${file.percent} %';
    return '${file.track!.uploadedBy} · ${_size(file.track!.size)}';
  }

  bool _matches(String title) {
    final query = _search.text.trim().toLowerCase();
    return query.isEmpty || title.toLowerCase().contains(query);
  }

  /// What the search field finds. The server has no search endpoint (api-docs.md, Upcoming),
  /// so this filters the library the page loaded. Without a query nothing is a result, because
  /// without a query the page shows its sections instead of a result list.
  List<LibraryEntry> _results() {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return const [];
    return [for (final entry in _library) if (_matches(entry.title)) entry];
  }

  /// One action on the shared player at a time. The page rebuilds after every one of them:
  /// a player that is only paused does not report anything, so a page that rebuilt only on
  /// the tap itself would keep the icon from before the tap.
  Future<void> _control(Future<void> Function() action) async {
    if (_busy) return;

    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      // A player that cannot open a song is not a JSON error, so the message is ours there.
      if (mounted) setState(() => _note = error is QueueException ? error.message : 'Das Lied konnte nicht gespielt werden: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opening a search result fills the queue with that one song and plays it, the way the
  /// Playlists page starts a playlist. The player only ever reads a queue, so a song picked
  /// here and a song from a playlist play exactly the same way.
  Future<void> _play(LibraryEntry entry) => _control(() async {
    // The name the queue panel shows for these rows is what this page filled them with: the
    // library. The server answer does not say that.
    widget.player.queue.fill(await widget.queues.fill(QueueSource.track(entry.id)), fromName: 'der Bibliothek');
    await widget.player.playCurrent();
  });

  /// The queue panel, with this page's own wiring. It is the same widget the queue route
  /// builds, so a song started here is the same song the panel shows.
  Widget _queuePanel() => QueuePanel(
    queues: widget.queues,
    playlists: widget.playlists,
    queue: widget.player.queue,
    player: widget.player,
    session: widget.session,
    // Closing goes back to the page the panel was opened from. The player is the app's
    // player, so nothing about the audio changes.
    onClose: () => setState(() => _queueOpen = false),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return LayoutBuilder(builder: (context, constraints) {
      // Below this width the sidebar has no room, the content takes the screen.
      // For a phone the upgrade would be a drawer.
      final wide = constraints.maxWidth >= 760;
      final results = _results();

      return Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          child: Row(
            children: [
              if (wide) _sidebar(constraints.maxHeight),
              Expanded(
                child: Column(
                  children: [
                    _topBar(),
                    // On a phone the queue is its own view, so it takes the place of the page.
                    Expanded(
                      child: _queueOpen && !wide
                          ? _queuePanel()
                          : SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _greeting(),
                                  const SizedBox(height: 24),
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 10,
                                    children: [
                                      _chip('Dein Mix', Icons.equalizer),
                                      _chip('Charts', Icons.star),
                                      _chip('Radio', Icons.radio),
                                      _chip('Eigene Dateien hochladen', Icons.upload, onPressed: _picking ? null : _upload),
                                      _chip('Entdecken', Icons.explore),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    _uploadHint,
                                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                                  ),
                                  if (_note != null) ...[
                                    const SizedBox(height: 16),
                                    Text(_note!, style: TextStyle(color: scheme.error)),
                                  ],
                                  if (results.isNotEmpty) ...[
                                    _section('Suchergebnisse'),
                                    _row([for (final entry in results) _songCard(entry)]),
                                  ],
                                  _section('Eigene Dateien'),
                                  _row([
                                    for (final file in _files.where((file) => _matches(_title(file)))) _fileCard(file),
                                    if (_files.isEmpty && _matches('Eigene Dateien')) _uploadCard(),
                                  ]),
                                  _section('Zuletzt gehört'),
                                  _row([
                                    for (final item in _placeholders.where((item) => _matches(item.title))) _card(item),
                                  ]),
                                ],
                              ),
                            ),
                    ),
                    _playerBar(),
                  ],
                ),
              ),
              // On a desktop the page stays where it is and the queue is the panel beside it.
              if (_queueOpen && wide) SizedBox(width: 360, height: constraints.maxHeight, child: _queuePanel()),
            ],
          ),
        ),
      );
    });
  }

  Widget _sidebar(double height) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 248,
      height: height,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The lines in the logo asset are thin, so at this size they come out
            // soft — that is the small mark the mock shows.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: SaphireLogo(size: 44),
            ),
            for (final item in _navItems) _navItem(item.label, item.icon, selected: item.selected, route: item.route),
            _heading('Deine Inhalte'),
            for (final item in [
              (label: 'Eigene Dateien', icon: Icons.add),
              (label: 'Playlists', icon: Icons.playlist_play),
              (label: 'Alben', icon: Icons.album),
              (label: 'Künstler*innen', icon: Icons.people),
            ])
              _navItem(item.label, item.icon),
            _heading('Playlists'),
            // The sidebar is the list of what is there, the search field above
            // only filters the page.
            for (final item in _placeholders)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
                child: Row(
                  children: [
                    _thumb(item.icon),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.title, style: theme.textTheme.labelLarge),
                          Text(
                            item.meta,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _heading(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  Widget _navItem(String label, IconData icon, {bool selected = false, String route = ''}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // A row with no route behind it stays a label. Only what has an endpoint can be
    // opened, and that is what the routes in app/router.dart are.
    final canOpen = route.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: InkWell(
        onTap: canOpen ? () => context.go(route) : null,
        child: Row(
          children: [
            Icon(icon, size: 20, color: selected ? scheme.primary : scheme.onSurfaceVariant),
            const SizedBox(width: 14),
            Flexible(child: Text(label, style: theme.textTheme.labelLarge)),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = _user?.username;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
      child: Row(
        children: [
          Icon(Icons.chevron_left, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
          const SizedBox(width: 16),
          Expanded(
            // The server has no search endpoint, so what is typed here filters the library
            // this page loaded once (see the shortcut in library/data/library_repository.dart).
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(hintText: 'Was möchtest du wiedergeben?'),
            ),
          ),
          const SizedBox(width: 16),
          Icon(Icons.notifications_outlined, color: scheme.onSurfaceVariant),
          const SizedBox(width: 16),
          PopupMenuButton<String>(
            tooltip: 'Konto',
            offset: const Offset(0, 44),
            onSelected: (value) {
              if (value != 'logout') return;
              // There is no logout endpoint yet (api-docs.md, Upcoming), so
              // dropping the token here is the whole logout on this side.
              widget.repository.logout();
              context.go('/login');
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'logout', child: Text('Abmelden')),
            ],
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(17),
              ),
              child: Text(
                name == null ? '?' : name.substring(0, 1).toUpperCase(),
                style: theme.textTheme.labelLarge?.copyWith(color: scheme.onPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _greeting() {
    final theme = Theme.of(context);
    final name = _user?.username;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            text: '${greetingFor(DateTime.now())}, ',
            style: theme.textTheme.displayLarge,
            children: [
              TextSpan(
                // The session check is still running on the first frames.
                text: name ?? '…',
                style: TextStyle(color: theme.colorScheme.primary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Hier sind deine Highlights für heute.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 24, 0, 12),
      child: Text(title, style: Theme.of(context).textTheme.titleLarge),
    );
  }

  Widget _row(List<Widget> cards) => Wrap(spacing: 12, runSpacing: 12, children: cards);

  Widget _card(({String title, String meta, IconData icon}) item) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SizedBox(
      width: 186,
      height: 186,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The mock has pictures here. Until the library has an API, a
              // gradient in the brand color stands in for one.
              Container(
                width: double.infinity,
                height: 96,
                alignment: Alignment.bottomLeft,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [scheme.primary.withValues(alpha: 0.35), scheme.surface],
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Icon(item.icon, color: scheme.onSurface),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                item.title,
                style: theme.textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                item.meta,
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A real library song: the same card as the placeholder rows, but it can be opened,
  /// because a search result is something the user means to play. The line under the title
  /// says where the row came from, so a real song can be told apart from a mock row.
  Widget _songCard(LibraryEntry entry) {
    return InkWell(
      onTap: _busy ? null : () => _play(entry),
      child: _card((title: entry.title, meta: 'Bibliothek', icon: Icons.audio_file)),
    );
  }

  /// One picked file: its name and the answer for this file only, so the results
  /// of a batch do not mix into one message.
  Widget _fileCard(_UploadFile file) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = file.error != null;

    return SizedBox(
      width: 186,
      height: 186,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          // A refused file is marked as refused, so the row can be told apart.
          border: Border.all(color: failed ? scheme.error : scheme.outline),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(failed ? Icons.error : Icons.audio_file, color: failed ? scheme.error : scheme.primary),
              const Spacer(),
              Text(
                _title(file),
                style: theme.textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                _result(file),
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              // The bar is only for a file that is still on its way.
              if (!failed && file.track == null) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: file.percent / 100, minHeight: 3),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _uploadCard() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SizedBox(
      width: 186,
      height: 186,
      child: FilledButton(
        onPressed: _picking ? null : _upload,
        style: FilledButton.styleFrom(
          // The card stays in the card color, only the plus is the accent.
          backgroundColor: scheme.surfaceContainer,
          foregroundColor: scheme.onSurface,
          padding: const EdgeInsets.all(14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.add, color: scheme.primary),
            const Spacer(),
            Text(
              'Datei auswählen',
              style: theme.textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              'Noch nichts hochgeladen',
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, IconData icon, {VoidCallback? onPressed}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (onPressed == null) {
      // Nothing is behind this on the server, so it is a label and not a button.
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Text(label, style: theme.textTheme.labelLarge),
          ],
        ),
      );
    }

    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon, size: 18), const SizedBox(width: 10), Text(label)],
      ),
    );
  }

  Widget _thumb(IconData icon) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
    );
  }

  /// The bar at the bottom: the song the shared player is playing. This page does not own a
  /// player, so the bar shows the same queue the Playlists page filled, and its buttons go
  /// through the same player. What the player cannot do — seek, repeat, shuffle — is not here.
  Widget _playerBar() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = widget.player.queue.current;
    final playing = widget.player.playing;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outline))),
      child: Row(
        children: [
          Icon(Icons.audio_file, size: 22, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  current == null ? 'Nichts wird abgespielt' : current.title,
                  style: theme.textTheme.labelLarge,
                ),
                Text(
                  widget.player.failure ??
                      (current == null
                          ? 'Suche ein Lied und öffne es, oder fülle die Warteschlange.'
                          : 'Warteschlange · Slot ${current.position}'),
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: playing ? 'Pause' : 'Abspielen',
            onPressed: _busy ? null : () => _control(() => playing ? widget.player.pause() : widget.player.playCurrent()),
            icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          ),
          IconButton(
            tooltip: 'Nächstes Lied',
            onPressed: _busy ? null : () => _control(() => widget.player.next()),
            icon: const Icon(Icons.skip_next),
          ),
          IconButton(
            // Opening the queue from the bar must not interrupt what is playing: the panel
            // only reads the list, it never touches the player.
            tooltip: _queueOpen ? 'Warteschlange schließen' : 'Warteschlange öffnen',
            onPressed: () => setState(() => _queueOpen = !_queueOpen),
            icon: const Icon(Icons.queue_music),
          ),
        ],
      ),
    );
  }

  String _size(int bytes) {
    return bytes >= 1000000 ? '${(bytes / 1000000).toStringAsFixed(1)} MB' : '${(bytes / 1000).round()} kB';
  }
}


