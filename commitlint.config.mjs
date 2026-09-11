export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // `deps` is not a config-conventional type. It is accepted so that a
    // dependency bump which does reach users can be typed `deps` and routed to
    // a Dependencies changelog section. Nothing here emits it today -- see
    // `.github/dependabot.yaml` -- but the type stays uniform across the repos.
    'type-enum': [
      2,
      'always',
      [
        'build',
        'chore',
        'ci',
        'deps',
        'docs',
        'feat',
        'fix',
        'perf',
        'refactor',
        'revert',
        'style',
        'test',
      ],
    ],
    // No scope-enum: this repo is a single package, so scope is decorative.
    // Subject case relaxation: allow identifiers like Palette or OpportunityQuery
    // to start a subject. Matches yo61/jobhound's commitlint config.
    'subject-case': [0],
  },
};
