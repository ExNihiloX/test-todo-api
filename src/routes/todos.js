const express = require('express');
const TodoStore = require('../models/TodoStore');

const router = express.Router();
const store = new TodoStore();

// GET /api/todos - List all todos
router.get('/', (req, res) => {
  try {
    const todos = store.getAll();
    res.json({ todos });
  } catch (_error) {
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /api/todos - Create new todo
router.post('/', (req, res) => {
  try {
    const { title } = req.body;

    if (!title || typeof title !== 'string' || title.trim() === '') {
      return res.status(400).json({ error: 'Title is required' });
    }

    const todo = store.create(title.trim());
    res.status(201).json(todo);
  } catch (_error) {
    res.status(500).json({ error: 'Internal server error' });
  }
});

// PUT /api/todos/:id - Update todo
router.put('/:id', (req, res) => {
  try {
    const { id } = req.params;
    const { title, completed } = req.body;

    const existing = store.getById(id);
    if (!existing) {
      return res.status(404).json({ error: 'Todo not found' });
    }

    const updates = {};
    if (title !== undefined) {
      if (typeof title !== 'string' || title.trim() === '') {
        return res.status(400).json({ error: 'Invalid title' });
      }
      updates.title = title.trim();
    }
    if (completed !== undefined) {
      if (typeof completed !== 'boolean') {
        return res.status(400).json({ error: 'Completed must be a boolean' });
      }
      updates.completed = completed;
    }

    const updated = store.update(id, updates);
    res.json(updated);
  } catch (_error) {
    res.status(500).json({ error: 'Internal server error' });
  }
});

// DELETE /api/todos/:id - Delete todo
router.delete('/:id', (req, res) => {
  try {
    const { id } = req.params;

    const success = store.delete(id);
    if (!success) {
      return res.status(404).json({ error: 'Todo not found' });
    }

    res.json({ success: true });
  } catch (_error) {
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Export store for testing
router.store = store;

module.exports = router;
