// Shared by the fixture pages: what a page reports goes to the fixture server, which grades the run.
// `record` resolves once the server answered, so a page can show the outcome the way a real site would.
window.record = (event, data = {}) =>
  fetch('api/' + event, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) })
    .then(response => response.json())
