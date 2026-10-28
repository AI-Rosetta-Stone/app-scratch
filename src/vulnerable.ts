import { exec } from 'child_process';

// Deliberately vulnerable: a recognized CodeQL taint source (process.argv) flows
// unsanitized into a shell command (js/command-line-injection, security-extended,
// high severity). Intentional, for the t/4567 live-fire -- must never merge.
const userSuppliedArg = process.argv[2];
exec('echo ' + userSuppliedArg);
