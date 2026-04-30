import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:get/get.dart';

class CreatePollResult {
  const CreatePollResult({
    required this.question,
    required this.options,
    required this.endsAtUtc,
    required this.visibleAnswers,
  });

  final String question;
  final List<String> options;
  final DateTime endsAtUtc;
  final bool visibleAnswers;
}

class CreatePollScreen extends StatefulWidget {
  const CreatePollScreen({
    super.key,
    this.initialQuestion,
    this.initialOptions,
    this.initialEndsAtUtc,
    this.initialVisibleAnswers,
    this.title = 'Create New Poll',
    this.submitLabel = 'Send Poll',
  });

  final String? initialQuestion;
  final List<String>? initialOptions;
  final DateTime? initialEndsAtUtc;
  final bool? initialVisibleAnswers;
  final String title;
  final String submitLabel;

  @override
  State<CreatePollScreen> createState() => _CreatePollScreenState();
}

class _CreatePollScreenState extends State<CreatePollScreen> {
  static const _card = Color(0xFF000000);
  static const _field = Color(0xFF000000);
  static const _stroke = Color(0xFF25343D);
  static const _accent = Color(0xFF00A884);
  static const _text = Color(0xFFE9EDEF);
  static const _muted = Color(0xFF8696A0);

  final TextEditingController _question = TextEditingController();
  final List<TextEditingController> _options = [
    TextEditingController(),
    TextEditingController(),
  ];
  DateTime? _endsAtLocal;
  bool _visibleAnswers = true;

  @override
  void initState() {
    super.initState();
    final q = widget.initialQuestion?.trim() ?? '';
    if (q.isNotEmpty) _question.text = q;
    final opts = widget.initialOptions ?? const <String>[];
    final cleaned = opts.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (cleaned.length >= 2) {
      for (final o in _options) {
        o.dispose();
      }
      _options
        ..clear()
        ..addAll(cleaned.map((e) => TextEditingController(text: e)));
    }
    if (widget.initialEndsAtUtc != null) {
      _endsAtLocal = widget.initialEndsAtUtc!.toLocal();
    }
    if (widget.initialVisibleAnswers != null) {
      _visibleAnswers = widget.initialVisibleAnswers!;
    }
  }

  @override
  void dispose() {
    _question.dispose();
    for (final o in _options) {
      o.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDateTime() async {
    final now = DateTime.now();
    final start = _endsAtLocal ?? now.add(const Duration(hours: 24));
    final date = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 30)),
      initialDate: start,
    );
    if (!mounted || date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(start),
    );
    if (!mounted || time == null) return;
    setState(() {
      _endsAtLocal = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  void _submit() {
    final question = _question.text.trim();
    final options = _options.map((e) => e.text.trim()).where((e) => e.isNotEmpty).toList();
    if (question.isEmpty) {
      Get.snackbar('Poll', 'Question is required');
      return;
    }
    if (options.length < 2) {
      Get.snackbar('Poll', 'At least 2 options are required');
      return;
    }
    if (options.length > 10) {
      Get.snackbar('Poll', 'Maximum 10 options allowed');
      return;
    }
    final endsAt = _endsAtLocal ?? DateTime.now().add(const Duration(hours: 24));
    Navigator.of(context).pop(
      CreatePollResult(
        question: question,
        options: options,
        endsAtUtc: endsAt.toUtc(),
        visibleAnswers: _visibleAnswers,
      ),
    );
  }

  InputDecoration _fieldDecoration({
    required String hint,
    Widget? prefixIcon,
    Widget? suffixIcon,
    bool showBorder = false,
  }) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: showBorder ? const BorderSide(color: _stroke) : BorderSide.none,
    );
    return InputDecoration(
      hintText: hint,
      hintStyle: GoogleFonts.ptSans(color: _muted, fontSize: 14),
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      counterText: '',
      filled: true,
      fillColor: _field,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: border,
      enabledBorder: border,
      focusedBorder: border,
    );
  }

  @override
  Widget build(BuildContext context) {
    final dateLabel = _endsAtLocal == null
        ? 'Default: 24h'
        : '${_endsAtLocal!.day}/${_endsAtLocal!.month}/${_endsAtLocal!.year} '
            '${TimeOfDay.fromDateTime(_endsAtLocal!).format(context)}';
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: _text),
        title: Text(
          widget.title,
          style: GoogleFonts.ptSans(color: _text, fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 18),
        children: [
          Container(
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _stroke),
            ),
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Question',
                  style: GoogleFonts.ptSans(
                    color: _text,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _question,
                  maxLength: 124,
                  minLines: 1,
                  maxLines: null,
                  style: GoogleFonts.ptSans(color: _text),
                  decoration: _fieldDecoration(
                    hint: 'Ask your question',
                    prefixIcon: const Icon(Icons.help_outline_rounded, color: _muted, size: 20),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _stroke),
            ),
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Options',
                      style: GoogleFonts.ptSans(
                        color: _text,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      '${_options.length}/10',
                      style: GoogleFonts.ptSans(
                        color: _accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                for (var i = 0; i < _options.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _options[i],
                            minLines: 1,
                            maxLines: null,
                            style: GoogleFonts.ptSans(color: _text),
                            decoration: _fieldDecoration(
                              hint: 'Option ${i + 1}',
                              showBorder: true,
                              prefixIcon: const Icon(
                                Icons.drag_handle_rounded,
                                color: _muted,
                                size: 19,
                              ),
                            ),
                          ),
                        ),
                        if (_options.length > 2)
                          IconButton(
                            onPressed: () => setState(() {
                              _options.removeAt(i).dispose();
                            }),
                            icon: const Icon(Icons.close_rounded, color: _muted),
                          ),
                      ],
                    ),
                  ),
                if (_options.length < 10)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(() => _options.add(TextEditingController())),
                      icon: const Icon(Icons.add_circle_outline_rounded, color: _accent),
                      label: Text(
                        'Add option',
                        style: GoogleFonts.ptSans(color: _accent, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _stroke),
            ),
            child: Column(
              children: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  leading: const Icon(Icons.schedule_rounded, color: _accent),
                  title: Text(
                    'Active Till',
                    style: GoogleFonts.ptSans(color: _text, fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(dateLabel, style: GoogleFonts.ptSans(color: _muted)),
                  trailing: const Icon(Icons.keyboard_arrow_right_rounded, color: _muted),
                  onTap: _pickDateTime,
                ),
                const Divider(height: 1, color: _stroke),
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  activeThumbColor: _accent,
                  title: Text(
                    'Visible Answers',
                    style: GoogleFonts.ptSans(color: _text, fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    'Show who voted for each option',
                    style: GoogleFonts.ptSans(color: _muted),
                  ),
                  value: _visibleAnswers,
                  onChanged: (v) => setState(() => _visibleAnswers = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            icon: const Icon(Icons.send_rounded),
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              textStyle: GoogleFonts.ptSans(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            onPressed: _submit,
            label: Text(widget.submitLabel),
          ),
        ],
      ),
    );
  }
}
