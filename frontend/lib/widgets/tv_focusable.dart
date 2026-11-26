import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Kachel mit sichtbarem Fokusrahmen für D-Pad/Fernbedienung.
/// Auf Linux bleiben Mausklick und Rechtsklick unverändert erhalten.
class TvFocusable extends StatefulWidget {
  final Widget Function(bool focused) builder;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final void Function(TapDownDetails details)? onSecondaryTapDown;
  final bool autofocus;

  const TvFocusable({
    super.key,
    required this.builder,
    required this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.autofocus = false,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  final FocusNode _node = FocusNode();

  @override
  void initState() {
    super.initState();
    _node.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      widget.onTap();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.contextMenu ||
        event.logicalKey == LogicalKeyboardKey.keyC) {
      widget.onLongPress?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onSecondaryTapDown: widget.onSecondaryTapDown,
        child: widget.builder(_node.hasFocus),
      ),
    );
  }
}
