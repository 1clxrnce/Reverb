// favorite_button.dart
// Reusable heart button for favoriting songs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/ytmusic_api.dart';
import '../providers.dart';

class FavoriteButton extends ConsumerStatefulWidget {
  const FavoriteButton({
    super.key,
    required this.song,
    this.size = 28,
    this.color = Colors.white,
  });

  final Song song;
  final double size;
  final Color color;

  @override
  ConsumerState<FavoriteButton> createState() => _FavoriteButtonState();
}

class _FavoriteButtonState extends ConsumerState<FavoriteButton>
    with SingleTickerProviderStateMixin {
  bool? _localState;
  bool _isProcessing = false;
  late AnimationController _animController;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 1.3).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_isProcessing) return;

    final user = ref.read(authStateProvider).value;
    if (user == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Sign in to save favorites'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Sign In',
            onPressed: () => Navigator.pushNamed(context, '/sign-in'),
          ),
        ),
      );
      return;
    }

    final currentState =
        _localState ?? ref.read(isFavoriteProvider(widget.song.id)) ?? false;

    unawaited(_animController.forward().then((_) => _animController.reverse()));

    setState(() {
      _localState = !currentState;
      _isProcessing = true;
    });

    try {
      await ref
          .read(firestoreServiceProvider)
          .toggleFavorite(user.uid, widget.song);
      if (mounted) {
        setState(() {
          _localState = null;
          _isProcessing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _localState = null;
          _isProcessing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not update favorite'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authStateProvider).value;

    if (user == null) {
      return IconButton(
        icon: Icon(
          Icons.favorite_border,
          size: widget.size,
          color: widget.color.withOpacity(0.3),
        ),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        onPressed: _toggle,
      );
    }

    final isFavorite =
        _localState ?? ref.watch(isFavoriteProvider(widget.song.id)) ?? false;

    return ScaleTransition(
      scale: _scaleAnim,
      child: IconButton(
        icon: Icon(
          isFavorite ? Icons.favorite : Icons.favorite_border,
          size: widget.size,
          color: isFavorite ? Colors.white : widget.color,
        ),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        onPressed: _isProcessing ? null : _toggle,
      ),
    );
  }
}
