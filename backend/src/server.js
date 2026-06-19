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
const turnRoutes = require('./routes/turn');
const { setupSignaling } = require('./signaling');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  cors: { origin: '*', methods: ['GET', 'POST'] },
  transports: ['websocket', 'polling'],
});

// Firebase Admin (for push notifications)
// Place your serviceAccountKey.json in backend/
try {
  const serviceAccount = require('../serviceAccountKey.json');
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
  console.log('Firebase Admin initialized');
} catch {
  console.warn('serviceAccountKey.json not found — push notifications disabled');
  admin.initializeApp(); // Dummy init
}

app.use(cors());
app.use(express.json());
app.use((req, _, next) => { console.log(`[http] ${req.method} ${req.path} from ${req.ip}`); next(); });

// Health check
app.get('/health', (_, res) => res.json({ status: 'ok' }));

// Routes
app.use('/auth', authRoutes);
app.use('/users', usersRoutes);
app.use('/contacts', contactsRoutes);
app.use('/messages', messagesRoutes);
app.use('/turn-credentials', turnRoutes);

// WebSocket signaling
setupSignaling(io);

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`Pager server running on port ${PORT}`);
});
