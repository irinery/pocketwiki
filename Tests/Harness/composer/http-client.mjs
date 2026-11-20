const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const { bearer, thread_id, prepared_id, manifest_sha256 } = JSON.parse(Buffer.concat(chunks).toString('utf8'));
const response = await fetch(`http://127.0.0.1:${process.argv[2]}/v1/composer/resolve`, {
  method: 'POST', headers: { authorization: `Bearer ${bearer}`, 'content-type': 'application/json' },
  body: JSON.stringify({ thread_id, input: { prepared_id, manifest_sha256 } })
});
const payload = await response.json();
process.stdout.write(JSON.stringify({ status: response.status, text: payload.context?.text }));
