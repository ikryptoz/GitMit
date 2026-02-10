import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

const String kRtdbUrl = 'https://githubmessenger-7d2c6-default-rtdb.firebaseio.com';

FirebaseDatabase rtdb([FirebaseApp? app]) {
  final firebaseApp = app ?? Firebase.app();
  return FirebaseDatabase.instanceFor(
    app: firebaseApp,
    databaseURL: kRtdbUrl,
  );
}
