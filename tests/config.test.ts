import assert from "node:assert/strict";
import test from "node:test";
import { ConfigurationError, loadConfig } from "../src/config.js";

const validEnvironment = {
  NODE_ENV: "test",
  HOST: "127.0.0.1",
  PORT: "4000",
  DATABASE_URL: "postgres://tracker:tracker@localhost:5432/tracker",
  JWT_SECRET: "a-secret-key-that-is-at-least-32-characters-long",
};

test("loads valid environment configuration", () => {
  const config = loadConfig(validEnvironment);

  assert.equal(config.NODE_ENV, "test");
  assert.equal(config.PORT, 4000);
  assert.equal(config.HOST, "127.0.0.1");
});

test("reports missing configuration keys without values", () => {
  assert.throws(
    () => loadConfig({}),
    (error: unknown) => {
      assert.ok(error instanceof ConfigurationError);
      assert.match(error.message, /DATABASE_URL/);
      assert.match(error.message, /JWT_SECRET/);
      assert.doesNotMatch(error.message, /tracker|secret-key/);
      return true;
    },
  );
});

test("rejects invalid ports and weak JWT secrets", () => {
  assert.throws(() => loadConfig({
    ...validEnvironment,
    PORT: "70000",
    JWT_SECRET: "short",
  }), ConfigurationError);
});
