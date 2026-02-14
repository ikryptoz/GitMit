// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: constant_identifier_names

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        throw UnsupportedError('DefaultFirebaseOptions are not supported for this platform.');
      default:
        throw UnsupportedError('DefaultFirebaseOptions are not supported for this platform.');
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyCWyRZxUiKd94ZPLSiqZoVOf88d8qeRGMo',
    appId: '1:232503661603:android:26bab1ef5fec7310270d96',
    messagingSenderId: '232503661603',
    projectId: 'githubmessenger-7d2c6',
    databaseURL: 'https://githubmessenger-7d2c6-default-rtdb.firebaseio.com',
    storageBucket: 'githubmessenger-7d2c6.appspot.com',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: '',
    appId: '',
    messagingSenderId: '',
    projectId: '',
    databaseURL: '',
    storageBucket: '',
  );

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyCWyRZxUiKd94ZPLSiqZoVOf88d8qeRGMo',
    appId: '1:232503661603:web:26bab1ef5fec7310270d96',
    messagingSenderId: '232503661603',
    projectId: 'githubmessenger-7d2c6',
    authDomain: 'githubmessenger-7d2c6.firebaseapp.com',
    databaseURL: 'https://githubmessenger-7d2c6-default-rtdb.firebaseio.com',
    storageBucket: 'githubmessenger-7d2c6.appspot.com',
  );
}
