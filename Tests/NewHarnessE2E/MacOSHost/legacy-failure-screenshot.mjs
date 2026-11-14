// Select only the explicitly named fixture element; never export other UI attachments.
export function legacyFailureScreenshotPayload(activities) {
  const matches = [];
  const name = /^nh-legacy-fixture-failure_[0-9]+_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.png$/i;
  function visit(value) {
    if (!value || typeof value !== 'object') return;
    if (Array.isArray(value)) { for (const item of value) visit(item); return; }
    if (Array.isArray(value.attachments)) {
      for (const attachment of value.attachments) if (name.test(attachment.name || '')) matches.push(attachment);
    }
    for (const [key, child] of Object.entries(value)) if (key !== 'attachments') visit(child);
  }
  visit(activities);
  // xcresulttool can repeat the same attachment in nested activity views.
  // Collapse only identical references; distinct references remain ambiguous.
  const unique = [...new Map(matches.map(item => [JSON.stringify([item.name, item.payloadId, item.lifetime, item.uuid ?? null]), item])).values()];
  if (unique.length !== 1 || unique[0].lifetime !== 'keepAlways' || typeof unique[0].payloadId !== 'string' || unique[0].payloadId.length > 1024 || !/^0~[A-Za-z0-9_-]{10,}={0,2}$/.test(unique[0].payloadId)) {
    throw new Error('fixture screenshot unavailable or ambiguous');
  }
  return unique[0].payloadId;
}
