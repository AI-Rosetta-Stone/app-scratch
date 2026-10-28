import * as http from 'http';
import * as url from 'url';
import { exec } from 'child_process';

// Deliberately vulnerable: GitHub's own canonical js/command-line-injection
// example (security-extended, high severity). An HTTP request's query string
// is a recognized remote taint source flowing unsanitized into a shell exec.
// Intentional, for the t/4567 live-fire -- must never merge.
http
  .createServer(function (req, res) {
    const parsed = url.parse(req.url || '', true);
    exec('ls ' + parsed.query.path, function (err, stdout) {
      res.end(stdout);
    });
  })
  .listen(8080);
