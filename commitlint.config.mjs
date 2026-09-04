export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // No scope-enum: this repo is a single package, so scope is decorative.
    // Subject case relaxation: allow identifiers like Palette or OpportunityQuery
    // to start a subject. Matches yo61/jobhound's commitlint config.
    'subject-case': [0],
  },
};
