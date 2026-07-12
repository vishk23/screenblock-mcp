import 'dotenv/config';
import { loadConfig } from './config.js';
import { makePool, PgRepo } from './repo.js';
import { makeDb, SqliteRepo } from './repoSqlite.js';
import { Ladder, ApnsSender, NoopSender } from './push.js';
import { makeApp } from './app.js';

const config = loadConfig();
const repo = config.sqlitePath
  ? new SqliteRepo(makeDb(config.sqlitePath))
  : new PgRepo(makePool(config.databaseUrl));
const sender = config.apns ? await ApnsSender.create(config.apns) : new NoopSender();
const push = new Ladder(repo, sender);

const app = makeApp({ repo, push, config, sender });
app.listen(config.port, () => {
  console.log(`screencp server listening on :${config.port} (apns: ${config.apns ? 'on' : 'off'})`);
});
