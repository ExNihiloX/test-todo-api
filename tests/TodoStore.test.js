const TodoStore = require('../src/models/TodoStore');

describe('TodoStore', () => {
  let store;

  beforeEach(() => {
    store = new TodoStore();
  });

  describe('create', () => {
    it('creates todo with UUID', () => {
      const todo = store.create('Test task');
      expect(todo.id).toBeDefined();
      expect(todo.id).toMatch(/^[0-9a-f-]{36}$/i);
      expect(todo.title).toBe('Test task');
      expect(todo.completed).toBe(false);
    });
  });

  describe('getAll', () => {
    it('returns empty array initially', () => {
      expect(store.getAll()).toEqual([]);
    });

    it('returns all todos', () => {
      store.create('Task 1');
      store.create('Task 2');
      expect(store.getAll()).toHaveLength(2);
    });
  });

  describe('getById', () => {
    it('returns todo by ID', () => {
      const created = store.create('Test');
      const found = store.getById(created.id);
      expect(found).toEqual(created);
    });

    it('returns null for non-existent ID', () => {
      expect(store.getById('non-existent')).toBeNull();
    });
  });

  describe('update', () => {
    it('updates todo properties', () => {
      const todo = store.create('Original');
      const updated = store.update(todo.id, { title: 'Updated', completed: true });
      expect(updated.title).toBe('Updated');
      expect(updated.completed).toBe(true);
    });

    it('returns null for non-existent ID', () => {
      expect(store.update('non-existent', { title: 'Test' })).toBeNull();
    });
  });

  describe('delete', () => {
    it('deletes existing todo', () => {
      const todo = store.create('To delete');
      expect(store.delete(todo.id)).toBe(true);
      expect(store.getById(todo.id)).toBeNull();
    });

    it('returns false for non-existent ID', () => {
      expect(store.delete('non-existent')).toBe(false);
    });
  });
});
