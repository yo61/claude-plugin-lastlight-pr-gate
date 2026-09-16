export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // No scope-enum: this repo is a single package, so scope is decorative.
    // Subject case relaxation: allow identifiers like Palette or OpportunityQuery
    // to start a subject. Matches yo61/jobhound's commitlint config.
    'subject-case': [0],
    // Dependabot uses `chore(deps)` (see .github/dependabot.yaml), so tooling
    // bumps land as chores and stay out of the changelog and the releases they
    // would otherwise cut. `deps` stays in the enum below because commits in
    // this history already use it.
    'type-enum': [
      2,
      'always',
      ['build', 'chore', 'ci', 'deps', 'docs', 'feat', 'fix', 'perf', 'refactor', 'revert', 'style', 'test'],
    ],
  },
};
