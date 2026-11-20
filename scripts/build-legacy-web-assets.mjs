import { copyFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const destination = path.join(root, 'assets');
await mkdir(destination, { recursive: true });
await copyFile(path.join(root, 'node_modules/marked/lib/marked.umd.js'), path.join(destination, 'marked.min.js'));
