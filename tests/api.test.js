const request = require('supertest');
const app = require('../src/index');
const todosRouter = require('../src/routes/todos');

describe('Todo API', () => {
  beforeEach(() => {
    todosRouter.store.clear();
  });

  describe('GET /api/todos', () => {
    it('returns empty array initially', async () => {
      const res = await request(app).get('/api/todos');
      expect(res.status).toBe(200);
      expect(res.body.todos).toEqual([]);
    });

    it('returns all todos', async () => {
      todosRouter.store.create('Task 1');
      todosRouter.store.create('Task 2');

      const res = await request(app).get('/api/todos');
      expect(res.status).toBe(200);
      expect(res.body.todos).toHaveLength(2);
    });

    it('returns todos with id, title, completed fields', async () => {
      todosRouter.store.create('Test task');

      const res = await request(app).get('/api/todos');
      expect(res.status).toBe(200);
      expect(res.body.todos).toHaveLength(1);

      const todo = res.body.todos[0];
      expect(todo).toHaveProperty('id');
      expect(todo).toHaveProperty('title', 'Test task');
      expect(todo).toHaveProperty('completed', false);
      expect(typeof todo.id).toBe('string');
      expect(typeof todo.title).toBe('string');
      expect(typeof todo.completed).toBe('boolean');
    });
  });

  describe('POST /api/todos', () => {
    it('creates todo with title', async () => {
      const res = await request(app)
        .post('/api/todos')
        .send({ title: 'New task' });

      expect(res.status).toBe(201);
      expect(res.body.id).toBeDefined();
      expect(res.body.title).toBe('New task');
      expect(res.body.completed).toBe(false);
    });

    it('returns 400 if title missing', async () => {
      const res = await request(app)
        .post('/api/todos')
        .send({});

      expect(res.status).toBe(400);
      expect(res.body.error).toBe('Title is required');
    });

    it('returns 400 if title empty', async () => {
      const res = await request(app)
        .post('/api/todos')
        .send({ title: '  ' });

      expect(res.status).toBe(400);
      expect(res.body.error).toBe('Title is required');
    });

    it('returns 400 if title is not a string', async () => {
      const res = await request(app)
        .post('/api/todos')
        .send({ title: 123 });

      expect(res.status).toBe(400);
      expect(res.body.error).toBe('Title is required');
    });

    it('trims whitespace from title', async () => {
      const res = await request(app)
        .post('/api/todos')
        .send({ title: '  Trimmed task  ' });

      expect(res.status).toBe(201);
      expect(res.body.title).toBe('Trimmed task');
    });

    it('returns todo with valid UUID', async () => {
      const res = await request(app)
        .post('/api/todos')
        .send({ title: 'UUID test' });

      expect(res.status).toBe(201);
      expect(res.body.id).toMatch(/^[0-9a-f-]{36}$/i);
    });

    it('persists created todo', async () => {
      const createRes = await request(app)
        .post('/api/todos')
        .send({ title: 'Persisted task' });

      expect(createRes.status).toBe(201);

      const listRes = await request(app).get('/api/todos');
      expect(listRes.body.todos).toHaveLength(1);
      expect(listRes.body.todos[0].id).toBe(createRes.body.id);
    });
  });

  describe('PUT /api/todos/:id', () => {
    it('updates todo title', async () => {
      const todo = todosRouter.store.create('Original');

      const res = await request(app)
        .put(`/api/todos/${todo.id}`)
        .send({ title: 'Updated' });

      expect(res.status).toBe(200);
      expect(res.body.title).toBe('Updated');
    });

    it('updates todo completed status', async () => {
      const todo = todosRouter.store.create('Task');

      const res = await request(app)
        .put(`/api/todos/${todo.id}`)
        .send({ completed: true });

      expect(res.status).toBe(200);
      expect(res.body.completed).toBe(true);
    });

    it('updates both title and completed', async () => {
      const todo = todosRouter.store.create('Original');

      const res = await request(app)
        .put(`/api/todos/${todo.id}`)
        .send({ title: 'Updated', completed: true });

      expect(res.status).toBe(200);
      expect(res.body.title).toBe('Updated');
      expect(res.body.completed).toBe(true);
      expect(res.body.id).toBe(todo.id);
    });

    it('preserves id when updating', async () => {
      const todo = todosRouter.store.create('Original');
      const originalId = todo.id;

      const res = await request(app)
        .put(`/api/todos/${todo.id}`)
        .send({ title: 'Updated' });

      expect(res.status).toBe(200);
      expect(res.body.id).toBe(originalId);
    });

    it('returns 404 for non-existent id', async () => {
      const res = await request(app)
        .put('/api/todos/non-existent')
        .send({ title: 'Test' });

      expect(res.status).toBe(404);
      expect(res.body.error).toBe('Todo not found');
    });

    it('returns 400 for empty title', async () => {
      const todo = todosRouter.store.create('Original');

      const res = await request(app)
        .put(`/api/todos/${todo.id}`)
        .send({ title: '' });

      expect(res.status).toBe(400);
      expect(res.body.error).toBe('Invalid title');
    });

    it('returns 400 for whitespace-only title', async () => {
      const todo = todosRouter.store.create('Original');

      const res = await request(app)
        .put(`/api/todos/${todo.id}`)
        .send({ title: '   ' });

      expect(res.status).toBe(400);
      expect(res.body.error).toBe('Invalid title');
    });

    it('returns 400 for non-string title', async () => {
      const todo = todosRouter.store.create('Original');

      const res = await request(app)
        .put(`/api/todos/${todo.id}`)
        .send({ title: 123 });

      expect(res.status).toBe(400);
      expect(res.body.error).toBe('Invalid title');
    });

    it('returns 400 for non-boolean completed', async () => {
      const todo = todosRouter.store.create('Original');

      const res = await request(app)
        .put(`/api/todos/${todo.id}`)
        .send({ completed: 'true' });

      expect(res.status).toBe(400);
      expect(res.body.error).toBe('Completed must be a boolean');
    });

    it('trims whitespace from title', async () => {
      const todo = todosRouter.store.create('Original');

      const res = await request(app)
        .put(`/api/todos/${todo.id}`)
        .send({ title: '  Trimmed  ' });

      expect(res.status).toBe(200);
      expect(res.body.title).toBe('Trimmed');
    });

    it('can set completed to false', async () => {
      const todo = todosRouter.store.create('Task');
      todosRouter.store.update(todo.id, { completed: true });

      const res = await request(app)
        .put(`/api/todos/${todo.id}`)
        .send({ completed: false });

      expect(res.status).toBe(200);
      expect(res.body.completed).toBe(false);
    });

    it('persists changes', async () => {
      const todo = todosRouter.store.create('Original');

      await request(app)
        .put(`/api/todos/${todo.id}`)
        .send({ title: 'Updated', completed: true });

      const listRes = await request(app).get('/api/todos');
      const updated = listRes.body.todos.find(t => t.id === todo.id);

      expect(updated.title).toBe('Updated');
      expect(updated.completed).toBe(true);
    });
  });

  describe('DELETE /api/todos/:id', () => {
    it('deletes existing todo', async () => {
      const todo = todosRouter.store.create('To delete');

      const res = await request(app)
        .delete(`/api/todos/${todo.id}`);

      expect(res.status).toBe(200);
      expect(res.body.success).toBe(true);
    });

    it('returns 404 for non-existent id', async () => {
      const res = await request(app)
        .delete('/api/todos/non-existent');

      expect(res.status).toBe(404);
    });
  });
});
