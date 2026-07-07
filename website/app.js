import { initializeApp } from "https://www.gstatic.com/firebasejs/10.8.0/firebase-app.js";
import { getFirestore, doc, onSnapshot, updateDoc, increment, collection, addDoc, serverTimestamp } from "https://www.gstatic.com/firebasejs/10.8.0/firebase-firestore.js";

// Firebase configuration for pinmage-billio project
const firebaseConfig = {
  projectId: "pinmage-billio",
  appId: "1:294024078840:web:68d6bd175d6152f2b3e20d",
  storageBucket: "pinmage-billio.firebasestorage.app",
  apiKey: "AIzaSyC4OOidTETIaHsGsGLu8Q9jEHHIv0SfMi8",
  authDomain: "pinmage-billio.firebaseapp.com",
  messagingSenderId: "294024078840",
  measurementId: "G-J9WLRZSS1Z"
};

// Initialize Firebase with resilience
let db = null;
try {
  const firebaseApp = initializeApp(firebaseConfig);
  db = getFirestore(firebaseApp);
} catch (error) {
  console.error("Firebase failed to initialize:", error);
}

// App version — loaded dynamically from version.json
let APP_VERSION = "unknown";

// Asynchronously pre-fetch user's public IP address for download metadata logging
let userIpAddress = "unknown";
async function fetchUserIp() {
  try {
    const response = await fetch("https://api.ipify.org?format=json");
    if (response.ok) {
      const data = await response.json();
      userIpAddress = data.ip || "unknown";
    }
  } catch (error) {
    console.warn("Could not pre-fetch public IP address:", error);
  }
}

document.addEventListener("DOMContentLoaded", () => {
  initAppVersion();
  initDownloadTracker();
  fetchUserIp(); // Begin fetching IP in the background
});

/**
 * Loads app version from version.json and updates the DOM.
 */
async function initAppVersion() {
  try {
    const response = await fetch('./version.json');
    if (!response.ok) throw new Error('Not found');
    const data = await response.json();
    APP_VERSION = data.version || "unknown";
    const versionEl = document.querySelector('.version-tag');
    if (versionEl && data.version) {
      const build = data.build ? ` (Build ${data.build})` : '';
      versionEl.textContent = `v${data.version}${build} • macOS 13+ • DMG`;
    }
  } catch {
    const versionEl = document.querySelector('.version-tag');
    if (versionEl) {
      versionEl.textContent = 'v1.0.0 • macOS 13+ • DMG';
    }
  }
}

/**
 * Listens to Firestore download statistics and updates the DOM in real-time.
 * Intercepts download button clicks to log analytics.
 */
function initDownloadTracker() {
  const downloadBtn = document.getElementById("download-btn");

  if (downloadBtn) {
    downloadBtn.addEventListener("click", (e) => {
      e.preventDefault();
      handleDownload();
    });
  }

  if (!db) {
    console.warn("Firestore not initialized. Realtime counter disabled.");
    return;
  }

  // Set up real-time listener for the aggregate download count
  try {
    const docRef = doc(db, "stats", "pinmage");
    onSnapshot(docRef, (snapshot) => {
      if (snapshot.exists()) {
        const data = snapshot.data();
        const count = data.download_count || 0;
        const counterEl = document.getElementById("download-counter");
        const counterTextEl = document.getElementById("counter-text");
        if (counterEl && counterTextEl) {
          counterTextEl.textContent = count.toLocaleString();
          counterEl.classList.add("visible");
        }
      }
    }, (error) => {
      console.warn("Firestore listener warning:", error);
    });
  } catch (error) {
    console.error("Error establishing Firestore listener:", error);
  }
}

/**
 * Triggers the DMG download and logs the event to Firestore atomically.
 */
async function handleDownload() {
  // 1. Instantly trigger the DMG download for zero user-perceived lag
  const downloadUrl = "./Pinmage.dmg";
  const link = document.createElement("a");
  link.href = downloadUrl;
  link.setAttribute("download", `Pinmage${APP_VERSION !== "unknown" ? `-${APP_VERSION}` : ""}.dmg`);
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);

  // 2. Perform background analytical logging to Firestore
  if (!db) return;

  try {
    // A. Increment aggregate counter document
    const docRef = doc(db, "stats", "pinmage");
    const updatePromise = updateDoc(docRef, {
      download_count: increment(1)
    });

    // B. Log detailed event metadata for historical analysis
    const logCollection = collection(db, "downloads");
    const logPromise = addDoc(logCollection, {
      ip: userIpAddress,
      version: APP_VERSION,
      timestamp: serverTimestamp()
    });

    // Run both writes concurrently in the background
    await Promise.all([updatePromise, logPromise]);
    console.log("Download analytics logged successfully.");
  } catch (error) {
    console.warn("Could not log download analytics:", error);
  }
}
