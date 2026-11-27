// auth_service.dart
// Firebase authentication: email, Google, anonymous upgrade, password reset.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'firestore_service.dart';

class AuthFailure implements Exception {
  const AuthFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

class AuthService {
  AuthService({
    FirebaseAuth? auth,
    GoogleSignIn? googleSignIn,
  }) : _auth = auth ?? FirebaseAuth.instance,
       _googleSignIn = googleSignIn ?? GoogleSignIn(scopes: const ['email']);

  final FirebaseAuth _auth;
  final GoogleSignIn _googleSignIn;
  bool _googleSignInInProgress = false;
  FirebaseApp? _guestTransferApp;

  Stream<User?> get authStateChanges => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;
  bool get isSignedIn => _auth.currentUser != null;
  bool get isAnonymous => _auth.currentUser?.isAnonymous ?? false;
  bool get isEmailVerified => _auth.currentUser?.emailVerified ?? false;

  Future<UserCredential> signInAnonymously() async {
    try {
      return await _auth.signInAnonymously();
    } catch (e) {
      throw _handleError(e);
    }
  }

  Future<UserCredential> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      final cred = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      await cred.user?.sendEmailVerification();
      return cred;
    } catch (e) {
      throw _handleError(e);
    }
  }

  Future<UserCredential> signInWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      return await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } catch (e) {
      throw _handleError(e);
    }
  }

  Future<UserCredential> linkAnonymousToEmail({
    required String email,
    required String password,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null || !user.isAnonymous) {
        throw const AuthFailure('Not signed in as a guest');
      }

      final credential = EmailAuthProvider.credential(
        email: email.trim(),
        password: password,
      );
      final cred = await user.linkWithCredential(credential);
      await cred.user?.sendEmailVerification();
      return cred;
    } catch (e) {
      throw _handleError(e);
    }
  }

  Future<UserCredential?> signInWithGoogle({
    required Future<bool> Function(String email) confirmGuestTransfer,
  }) async {
    if (_googleSignInInProgress) {
      throw const AuthFailure('Google sign-in is already in progress');
    }
    _googleSignInInProgress = true;
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) return null;

      final googleAuth = await account.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final user = _auth.currentUser;
      if (user == null || !user.isAnonymous) {
        return await _auth.signInWithCredential(credential);
      }

      try {
        return await user.linkWithCredential(credential);
      } on FirebaseAuthException catch (e) {
        if (e.code != 'credential-already-in-use' &&
            e.code != 'email-already-in-use') {
          rethrow;
        }
      }

      if (!await confirmGuestTransfer(account.email)) return null;

      try {
        await _copyGuestLibrary(user.uid, credential);
      } catch (_) {
        throw const AuthFailure(
          'Could not finish copying your guest library. Try Google sign-in again.',
        );
      }

      if (_auth.currentUser?.uid != user.uid) {
        throw const AuthFailure(
          'Your active account changed. Try signing in again.',
        );
      }
      return await _auth.signInWithCredential(credential);
    } catch (e) {
      throw _handleError(e);
    } finally {
      _googleSignInInProgress = false;
    }
  }

  Future<void> _copyGuestLibrary(
    String guestUid,
    AuthCredential credential,
  ) async {
    // Keep the guest signed in on the primary app while writing as the destination.
    final app = _guestTransferApp ??= await Firebase.initializeApp(
      name: 'guestLibraryTransfer',
      options: _auth.app.options,
    );
    final destinationAuth = FirebaseAuth.instanceFor(app: app);
    try {
      final result = await destinationAuth.signInWithCredential(credential);
      final destinationUid = result.user!.uid;
      if (_auth.currentUser?.uid != guestUid) {
        throw const AuthFailure(
          'Your active account changed. Try signing in again.',
        );
      }
      await FirestoreService().copyGuestLibrary(
        guestUid,
        FirebaseFirestore.instanceFor(app: app),
        destinationUid,
      );
    } finally {
      await destinationAuth.signOut();
    }
  }

  Future<void> sendEmailVerification() async {
    try {
      final user = _auth.currentUser;
      if (user == null || user.isAnonymous) {
        throw const AuthFailure('No email account to verify');
      }
      if (user.emailVerified) return;
      await user.sendEmailVerification();
    } catch (e) {
      throw _handleError(e);
    }
  }

  Future<void> reloadUser() async {
    await _auth.currentUser?.reload();
  }

  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
      await _auth.signOut();
    } catch (e) {
      throw _handleError(e);
    }
  }

  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } catch (e) {
      throw _handleError(e);
    }
  }

  AuthFailure _handleError(Object e) {
    if (e is AuthFailure) return e;
    if (e is FirebaseAuthException) {
      switch (e.code) {
        case 'email-already-in-use':
          return const AuthFailure('This email is already registered');
        case 'invalid-email':
          return const AuthFailure('That email address looks invalid');
        case 'operation-not-allowed':
          return const AuthFailure(
            'This sign-in method is disabled. Check Firebase Auth providers.',
          );
        case 'weak-password':
          return const AuthFailure('Password must be at least 6 characters');
        case 'user-disabled':
          return const AuthFailure('This account has been disabled');
        case 'user-not-found':
          return const AuthFailure('No account found with this email');
        case 'wrong-password':
          return const AuthFailure('Incorrect password');
        case 'invalid-credential':
          return const AuthFailure('Invalid email or password');
        case 'too-many-requests':
          return const AuthFailure('Too many attempts. Try again later');
        case 'network-request-failed':
          return const AuthFailure('Network error. Check your connection');
        case 'account-exists-with-different-credential':
          return const AuthFailure(
            'An account already exists with this email. Sign in with email first.',
          );
        default:
          return AuthFailure(e.message ?? 'Authentication error: ${e.code}');
      }
    }
    return AuthFailure(e.toString());
  }
}
