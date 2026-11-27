import 'package:flutter/material.dart';

Future<bool> confirmGuestLibraryTransfer(
  BuildContext context,
  String email,
) async {
  final shouldCopy = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Copy your guest library?'),
      content: Text(
        'Copy your guest playlists, favorites, and listening history to '
        '$email before signing in? If a favorite or history entry is already '
        'in that account, Reverb keeps that version.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Stay as guest'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Copy and sign in'),
        ),
      ],
    ),
  );
  return shouldCopy ?? false;
}
