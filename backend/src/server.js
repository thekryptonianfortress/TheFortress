require('dotenv').config();
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const cors = require('cors');
const admin = require('firebase-admin');

const authRoutes = require('./auth');
const usersRoutes = require('./routes/users');
const contactsRoutes = require('./routes/contacts');
const messagesRoutes = require('./routes/messages');
const mediaRoutes = require('./routes/media');
const turnRoutes = require('./routes/turn');
const groupsRoutes = require('./routes/groups');
const { setupSignaling } = require('./signaling');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  cors: { origin: '*', methods: ['GET', 'POST'] },
  transports: ['websocket', 'polling'],
});

// Firebase Admin (for push notifications)
// Supports two init strategies:
//   1. serviceAccountKey.json file in backend/ (legacy)
//   2. Environment variables FIREBASE_PROJECT_ID, FIREBASE_PRIVATE_KEY, FIREBASE_CLIENT_EMAIL
try {
  let credential;
  if (process.env.FIREBASE_PRIVATE_KEY && process.env.FIREBASE_CLIENT_EMAIL) {
    credential = admin.credential.cert({
      projectId: process.env.FIREBASE_PROJECT_ID || 'pager-52c2d',
      privateKey: process.env.FIREBASE_PRIVATE_KEY.replace(/\\n/g, '\n'),
      clientEmail: process.env.FIREBASE_CLIENT_EMAIL,
    });
    admin.initializeApp({ credential });
    console.log('Firebase Admin initialized via environment variables');
  } else {
    const serviceAccount = require('../serviceAccountKey.json');
    admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
    console.log('Firebase Admin initialized via serviceAccountKey.json');
  }
} catch (e) {
  console.warn('Firebase Admin init failed — push notifications disabled:', e.message);
  try { admin.initializeApp(); } catch (_) {}
}

app.use(cors());
app.use(express.json());
app.use((req, _, next) => { console.log(`[http] ${req.method} ${req.path} from ${req.ip}`); next(); });

// Health check
app.get('/health', (_, res) => res.json({ status: 'ok' }));

// Static file serving for uploaded media
app.use('/uploads', express.static('/app/uploads'));

// Routes
app.use('/auth', authRoutes);
app.use('/users', usersRoutes);
app.use('/contacts', contactsRoutes);
app.use('/messages', messagesRoutes);
app.use('/media', mediaRoutes);
app.use('/turn-credentials', turnRoutes);
app.use('/groups', groupsRoutes);

// WebSocket signaling
setupSignaling(io);

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`Pager server running on port ${PORT}`);
});
