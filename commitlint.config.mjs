export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // No scope-enum: this repo is a single package, so scope is decorative.
    // Dependabot prefixes automated dependency-update commits with deps:.
    // Keep those commits linted instead of requiring a manual rewrite.
    'type-enum': [
      2,
      'always',
      ['build', 'chore', 'ci', 'deps', 'docs', 'feat', 'fix', 'perf', 'refactor', 'revert', 'style', 'test'],
    ],
    // Subject case relaxation: allow identifiers like Palette or OpportunityQuery
    // to start a subject. Matches yo61/jobhound's commitlint config.
    'subject-case': [0],
  },
};
