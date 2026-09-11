export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // No scope-enum: this repo is a single package, so scope is decorative.
    // Subject case relaxation: allow identifiers like Palette or OpportunityQuery
    // to start a subject. Matches yo61/jobhound's commitlint config.
    'subject-case': [0],
    // Dependabot is configured to use `deps` so release-please routes these
    // updates to the Dependencies changelog section instead of hiding them as
    // chores. Keep commitlint aligned with that repo convention.
    'type-enum': [
      2,
      'always',
      ['build', 'chore', 'ci', 'deps', 'docs', 'feat', 'fix', 'perf', 'refactor', 'revert', 'style', 'test'],
    ],
  },
};
