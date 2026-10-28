import { exec } from 'child_process';

// Deliberately vulnerable: unsanitized user input passed to a shell command
// (CodeQL js/command-line-injection, security-extended, high severity).
export function runUserCommand(userInput: string): void {
  exec('echo ' + userInput);
}
