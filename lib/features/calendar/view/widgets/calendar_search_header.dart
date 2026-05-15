import 'package:flutter/material.dart';

import '../../../../screens/chat/view/chat_view.dart';
import '../../../../theme/app_theme.dart';

/// Same row geometry as chat home header: pill + `SizedBox(10)` + `CircleAvatar(radius: 18)` (add icon).
class CalendarSearchHeader extends StatelessWidget {
  const CalendarSearchHeader({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onAddPressed,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onAddPressed;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Material(
            color: ChatScreen.appBarSurface,
            elevation: 6,
            shadowColor: Colors.black.withValues(alpha: 0.45),
            surfaceTintColor: Colors.transparent,
            borderRadius: BorderRadius.circular(28),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(Icons.search_rounded, size: 24, color: ChatScreen.searchHint),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 24,
                      child: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: controller,
                        builder: (context, value, _) {
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: controller,
                                  onChanged: onChanged,
                                  maxLines: 1,
                                  textAlignVertical: TextAlignVertical.center,
                                  style: ChatScreen.searchPillStyle(Colors.white),
                                  cursorColor: ChatScreen.appBarIcon,
                                  decoration: InputDecoration(
                                    hintText: 'Search events',
                                    hintStyle: ChatScreen.searchPillStyle(ChatScreen.searchHint),
                                    border: InputBorder.none,
                                    isDense: true,
                                    isCollapsed: true,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                              if (value.text.isNotEmpty)
                                SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: Tooltip(
                                    message: 'Clear',
                                    child: InkWell(
                                      onTap: () {
                                        controller.clear();
                                        onChanged('');
                                      },
                                      customBorder: const CircleBorder(),
                                      child: Icon(
                                        Icons.close_rounded,
                                        size: 18,
                                        color: ChatScreen.searchHint,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onAddPressed,
            customBorder: const CircleBorder(),
            child: CircleAvatar(
              radius: 18,
              backgroundColor: kPrimaryBlue.withValues(alpha: 0.92),
              child: const Icon(
                Icons.add,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
