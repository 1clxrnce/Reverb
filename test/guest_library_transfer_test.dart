import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:reverb/services/auth_service.dart';

void main() {
  test('declining the copy keeps the guest signed in', () async {
    final guest = _Guest(linkError: 'credential-already-in-use');
    final auth = _Auth(guest);
    final service = AuthService(auth: auth, googleSignIn: _GoogleSignIn());
    final prompted = <String>[];

    final result = await service.signInWithGoogle(
      confirmGuestTransfer: (email) async {
        prompted.add(email);
        return false;
      },
    );

    expect(result, isNull);
    expect(prompted, ['listener@example.com']);
    expect(auth.currentUser, same(guest));
    expect(auth.signIns, 0);
    expect(guest.deletions, 0);
  });

  test('a failed transfer leaves the guest signed in for retry', () async {
    final guest = _Guest(linkError: 'credential-already-in-use');
    final auth = _Auth(guest);
    final service = AuthService(auth: auth, googleSignIn: _GoogleSignIn());

    await expectLater(
      service.signInWithGoogle(confirmGuestTransfer: (_) async => true),
      throwsA(
        isA<AuthFailure>().having(
          (error) => error.message,
          'message',
          contains('Try Google sign-in again'),
        ),
      ),
    );

    expect(auth.currentUser, same(guest));
    expect(auth.signIns, 0);
    expect(guest.deletions, 0);
  });

  test('linking a new Google account keeps the guest UID', () async {
    final guest = _Guest();
    final auth = _Auth(guest);
    final service = AuthService(auth: auth, googleSignIn: _GoogleSignIn());

    final result = await service.signInWithGoogle(
      confirmGuestTransfer: (_) async {
        fail('Linking a new account needs no transfer');
      },
    );

    expect(result?.user?.uid, guest.uid);
    expect(auth.signIns, 0);
    expect(guest.deletions, 0);
  });
}

class _Guest extends Fake implements User {
  _Guest({this.linkError});
  final String? linkError;
  int deletions = 0;

  @override
  String get uid => 'guest';

  @override
  bool get isAnonymous => true;

  @override
  Future<UserCredential> linkWithCredential(AuthCredential credential) async {
    if (linkError != null) throw FirebaseAuthException(code: linkError!);
    return _Credential(this);
  }

  @override
  Future<void> delete() async {
    deletions++;
  }
}

class _Auth extends Fake implements FirebaseAuth {
  _Auth(this.currentUser);
  int signIns = 0;

  @override
  final User currentUser;

  @override
  FirebaseApp get app => throw StateError('Transfer Firebase app unavailable');

  @override
  Future<UserCredential> signInWithCredential(AuthCredential credential) async {
    signIns++;
    return _Credential(currentUser);
  }
}

class _Credential extends Fake implements UserCredential {
  _Credential(this.user);

  @override
  final User user;
}

class _GoogleSignIn extends Fake implements GoogleSignIn {
  @override
  Future<GoogleSignInAccount?> signIn() async => _GoogleAccount();
}

class _GoogleAccount extends Fake implements GoogleSignInAccount {
  @override
  String get email => 'listener@example.com';

  @override
  Future<GoogleSignInAuthentication> get authentication async =>
      _GoogleTokens();
}

class _GoogleTokens extends Fake implements GoogleSignInAuthentication {
  @override
  String get idToken => 'test-token';

  @override
  String? get accessToken => null;
}
