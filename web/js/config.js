export const firebaseConfig = {
    apiKey: "AIzaSyCWyRZxUiKd94ZPLSiqZoVOf88d8qeRGMo",
    authDomain: "githubmessenger-7d2c6.firebaseapp.com",
    databaseURL: "https://githubmessenger-7d2c6-default-rtdb.firebaseio.com",
    projectId: "githubmessenger-7d2c6",
    storageBucket: "githubmessenger-7d2c6.appspot.com",
    messagingSenderId: "232503661603",
    appId: "1:232503661603:web:26bab1ef5fec7310270d96"
};

if (typeof firebase !== 'undefined') {
    firebase.initializeApp(firebaseConfig);
}

export const db = typeof firebase !== 'undefined' ? firebase.database() : null;
export const auth = typeof firebase !== 'undefined' ? firebase.auth() : null;
