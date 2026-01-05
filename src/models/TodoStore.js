const { v4: uuidv4 } = require('uuid');

class TodoStore {
  constructor() {
    this.todos = [];
  }

  // Get all todos
  getAll() {
    return [...this.todos];
  }

  // Get todo by ID
  getById(id) {
    return this.todos.find(todo => todo.id === id) || null;
  }

  // Create new todo
  create(title) {
    const todo = {
      id: uuidv4(),
      title,
      completed: false
    };
    this.todos.push(todo);
    return todo;
  }

  // Update existing todo
  update(id, updates) {
    const index = this.todos.findIndex(todo => todo.id === id);
    if (index === -1) return null;

    this.todos[index] = {
      ...this.todos[index],
      ...updates,
      id // Ensure ID cannot be changed
    };
    return this.todos[index];
  }

  // Delete todo
  delete(id) {
    const index = this.todos.findIndex(todo => todo.id === id);
    if (index === -1) return false;

    this.todos.splice(index, 1);
    return true;
  }

  // Clear all todos (useful for testing)
  clear() {
    this.todos = [];
  }
}

module.exports = TodoStore;
