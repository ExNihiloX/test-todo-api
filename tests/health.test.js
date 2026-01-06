const request = require('supertest');
const app = require('../src/index');

describe('Health Endpoint', () => {
  describe('GET /health', () => {
    it('returns 200 status', async () => {
      const res = await request(app).get('/health');
      expect(res.status).toBe(200);
    });

    it('returns ok status in body', async () => {
      const res = await request(app).get('/health');
      expect(res.body.status).toBe('ok');
    });

    it('returns timestamp in body', async () => {
      const res = await request(app).get('/health');
      expect(res.body.timestamp).toBeDefined();
      expect(new Date(res.body.timestamp).toString()).not.toBe('Invalid Date');
    });

    it('returns JSON content type', async () => {
      const res = await request(app).get('/health');
      expect(res.headers['content-type']).toMatch(/application\/json/);
    });
  });
});
