import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../data/chat/chat_contact.dart';
import '../../../data/chat/chat_image_message.dart';
import '../../../data/chat/chat_group.dart';
import '../../../data/chat/chat_repository.dart';
import 'chat_thread_view.dart';

class GroupSharedContentScreen extends StatefulWidget {
  const GroupSharedContentScreen({
    super.key,
    required this.groupId,
    required this.contact,
  });

  final String groupId;
  final ChatContact contact;

  @override
  State<GroupSharedContentScreen> createState() => _GroupSharedContentScreenState();
}

class _GroupSharedContentScreenState extends State<GroupSharedContentScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this);
  final _types = const ['media', 'links', 'documents'];
  final Map<String, List<ChatGroupSharedItem>> _items = {};
  final Map<String, bool> _loading = {};
  final Map<String, bool> _hasMore = {};
  final Map<String, int> _page = {};

  @override
  void initState() {
    super.initState();
    for (final t in _types) {
      _items[t] = <ChatGroupSharedItem>[];
      _loading[t] = false;
      _hasMore[t] = true;
      _page[t] = 1;
    }
    _load(_types.first);
    _tab.addListener(() {
      if (_tab.indexIsChanging) return;
      final t = _types[_tab.index];
      if ((_items[t] ?? const []).isEmpty) {
        _load(t);
      }
    });
  }

  Future<void> _load(String type, {bool append = false}) async {
    if (_loading[type] == true) return;
    if (append && _hasMore[type] != true) return;
    setState(() => _loading[type] = true);
    try {
      final page = append ? ((_page[type] ?? 1) + 1) : 1;
      final res = await Get.find<ChatRepository>().fetchGroupSharedContent(
        groupId: widget.groupId,
        type: type,
        page: page,
        limit: 30,
      );
      if (!mounted) return;
      setState(() {
        if (append) {
          _items[type] = [...(_items[type] ?? const []), ...res.items];
        } else {
          _items[type] = res.items;
        }
        _page[type] = page;
        _hasMore[type] = res.hasMore;
      });
    } finally {
      if (mounted) setState(() => _loading[type] = false);
    }
  }

  String _label(String type) {
    switch (type) {
      case 'media':
        return 'Media';
      case 'links':
        return 'Links';
      case 'documents':
        return 'Documents';
    }
    return type;
  }

  List<_MediaTileData> _mediaTiles(List<ChatGroupSharedItem> items) {
    final out = <_MediaTileData>[];
    for (final it in items) {
      final img = ChatImageMessage.tryParse(it.body);
      if (img != null) {
        for (final e in img.items) {
          final url = e.url.trim();
          if (url.isEmpty) continue;
          out.add(
            _MediaTileData(
              messageId: it.id,
              url: url,
              isVideo: false,
              createdAt: it.createdAt,
            ),
          );
        }
        continue;
      }
      final vid = ChatVideoMessage.tryParse(it.body);
      if (vid != null) {
        final url = vid.item.url.trim();
        if (url.isEmpty) continue;
        out.add(
          _MediaTileData(
            messageId: it.id,
            url: url,
            isVideo: true,
            createdAt: it.createdAt,
          ),
        );
      }
    }
    return out;
  }

  String _firstUrl(String text) {
    final m = RegExp(r'https?:\/\/[^\s]+', caseSensitive: false).firstMatch(text);
    return m?.group(0)?.trim() ?? '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: const Color(0xFF000000),
        foregroundColor: Colors.white,
        title: const Text('Media, links, documents'),
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabs: _types.map((t) => Tab(text: _label(t))).toList(),
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: _types.map((type) {
          final items = _items[type] ?? const <ChatGroupSharedItem>[];
          final media = type == 'media' ? _mediaTiles(items) : const <_MediaTileData>[];
          return NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.pixels >= n.metrics.maxScrollExtent - 140) {
                _load(type, append: true);
              }
              return false;
            },
            child: type == 'media'
                ? GridView.builder(
                    padding: const EdgeInsets.all(10),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 4,
                      mainAxisSpacing: 4,
                    ),
                    itemCount: media.length + ((_loading[type] == true) ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i >= media.length) {
                        return const Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        );
                      }
                      final tile = media[i];
                      return InkWell(
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => ChatThreadScreen(
                                contact: widget.contact,
                                initialScrollToMessageId: tile.messageId,
                              ),
                            ),
                          );
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ColoredBox(
                                color: const Color(0xFF000000),
                                child: Image.network(
                                  tile.url,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) {
                                    return const Center(
                                      child: Icon(Icons.image_not_supported_rounded, color: Colors.white54),
                                    );
                                  },
                                ),
                              ),
                              if (tile.isVideo)
                                const Center(
                                  child: Icon(
                                    Icons.play_circle_fill_rounded,
                                    color: Colors.white,
                                    size: 28,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: items.length + ((_loading[type] == true) ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i >= items.length) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                        );
                      }
                      final it = items[i];
                      final doc = ChatDocumentMessage.tryParse(it.body);
                      final link = _firstUrl(it.body);
                      final isLinksTab = type == 'links';
                      final isDocsTab = type == 'documents';
                      final title = isDocsTab && doc != null
                          ? doc.name
                          : (isLinksTab && link.isNotEmpty ? link : it.body);
                      final subtitle = isDocsTab && doc != null
                          ? '${doc.ext.toUpperCase()} · ${doc.sizeBytes} bytes'
                          : (it.createdAt?.toLocal().toString() ?? '');
                      return Card(
                        color: const Color(0xFF000000),
                        child: ListTile(
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => ChatThreadScreen(
                                  contact: widget.contact,
                                  initialScrollToMessageId: it.id,
                                ),
                              ),
                            );
                          },
                          leading: isDocsTab
                              ? const Icon(Icons.description_rounded, color: Colors.white70)
                              : (isLinksTab
                                    ? const Icon(Icons.link_rounded, color: Colors.white70)
                                    : null),
                          title: Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.ptSans(color: Colors.white),
                          ),
                          subtitle: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.ptSans(color: Colors.white60, fontSize: 12),
                          ),
                        ),
                      );
                    },
                  ),
          );
        }).toList(),
      ),
    );
  }
}

class _MediaTileData {
  const _MediaTileData({
    required this.messageId,
    required this.url,
    required this.isVideo,
    this.createdAt,
  });

  final String messageId;
  final String url;
  final bool isVideo;
  final DateTime? createdAt;
}

