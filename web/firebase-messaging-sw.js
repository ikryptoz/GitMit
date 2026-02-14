/* eslint-disable no-undef */
importScripts('https://www.gstatic.com/firebasejs/10.7.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.7.1/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyCWyRZxUiKd94ZPLSiqZoVOf88d8qeRGMo',
  authDomain: 'githubmessenger-7d2c6.firebaseapp.com',
  databaseURL: 'https://githubmessenger-7d2c6-default-rtdb.firebaseio.com',
  projectId: 'githubmessenger-7d2c6',
  storageBucket: 'githubmessenger-7d2c6.appspot.com',
  messagingSenderId: '232503661603',
  appId: '1:232503661603:web:26bab1ef5fec7310270d96',
});

const messaging = firebase.messaging();

messaging.onBackgroundMessage((payload) => {
  const notification = payload?.notification || {};
  const title = notification.title || 'GitMit';
  const options = {
    body: notification.body || '',
    icon: '/icons/Icon-192.png',
    data: payload?.data || {},
  };

  self.registration.showNotification(title, options);
});
