const express = require('express');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const { v4: uuidv4 } = require('uuid');
const { authenticate } = require('../middleware');

const router = express.Router();

const UPLOADS_DIR = '/app/uploads';
if (!fs.existsSync(UPLOADS_DIR)) fs.mkdirSync(UPLOADS_DIR, { recursive: true });

const storage = multer.diskStorage({
  destination: UPLOADS_DIR,
  filename: (req, file, cb) => {
    const ext = path.extname(file.originalname).toLowerCase();
    cb(null, `${uuidv4()}${ext}`);
  },
});

const upload = multer({
  storage,
  limits: { fileSize: 100 * 1024 * 1024 }, // 100 MB
});

// POST /media/upload — upload an attachment, returns metadata
router.post('/upload', authenticate, upload.single('file'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No file provided' });

  const ext = path.extname(req.file.originalname).toLowerCase();
  const mime = req.file.mimetype || '';
  let type = 'file';
  if (['.jpg', '.jpeg', '.png', '.webp', '.heic', '.bmp'].includes(ext) || (mime.startsWith('image/') && mime !== 'image/gif')) type = 'image';
  else if (ext === '.gif' || mime === 'image/gif') type = 'gif';
  else if (['.mp4', '.mov', '.avi', '.mkv', '.webm', '.3gp'].includes(ext) || mime.startsWith('video/')) type = 'video';

  res.json({
    url: `/uploads/${req.file.filename}`,
    type,
    name: req.file.originalname,
    size: req.file.size,
  });
});

module.exports = router;
