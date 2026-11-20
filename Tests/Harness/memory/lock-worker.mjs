import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync(process.argv[2]);
db.exec('PRAGMA busy_timeout=5000; BEGIN IMMEDIATE');
process.send('locked');
setInterval(() => {}, 1000);
