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
    });

    it('returns 400 if title empty', async () => {
      const res = await request(app)
        .post('/api/todos')
        .send({ title: '  ' });

      expect(res.status).toBe(400);
    });

    it('trims whitespace from title', async () => {
      const res = await request(app)
        .post('/api/todos')
        .send({ title: '  Trimmed task  ' });

      expect(res.status).toBe(201);
      expect(res.body.title).toBe('Trimmed task');
    });

    it('returns 400 if title is not a string', async () => {
      const res = await request(app)
        .post('/api/todos')
        .send({ title: 123 });

      expect(res.status).toBe(400);
    });

    it('returns 400 if title is null', async () => {
      const res = await request(app)
        .post('/api/todos')
        .send({ title: null });

      expect(res.status).toBe(400);
    });

    it('persists created todo', async () => {
      const createRes = await request(app)
        .post('/api/todos')
        .send({ title: 'Persisted task' });

      expect(createRes.status).toBe(201);
      const id = createRes.body.id;

      const getRes = await request(app).get('/api/todos');
      expect(getRes.body.todos).toContainEqual(
        expect.objectContaining({ id, title: 'Persisted task' })
      );
    });

    it('returns complete todo object structure', async () => {
      const res = await request(app)
        .post('/api/todos')
        .send({ title: 'Structure test' });

      expect(res.status).toBe(201);
      expect(res.body).toHaveProperty('id');
      expect(res.body).toHaveProperty('title');
      expect(res.body).toHaveProperty('completed');
      expect(typeof res.body.id).toBe('string');
      expect(typeof res.body.title).toBe('string');
      expect(typeof res.body.completed).toBe('boolean');
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

    it('returns 404 for non-existent id', async () => {
      const res = await request(app)
        .put('/api/todos/non-existent')
        .send({ title: 'Test' });

      expect(res.status).toBe(404);
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
