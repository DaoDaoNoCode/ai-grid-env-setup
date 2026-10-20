// Self-hosted Renovate settings for .github/workflows/renovate.yaml. The repository's own
// renovate.json says what to update; this says where, and how to log in to quay.io/rhoai.
module.exports = {
  platform: 'github',
  repositories: [process.env.GITHUB_REPOSITORY],
  onboarding: false,
  requireConfig: 'required',
  hostRules: [
    {
      hostType: 'docker',
      matchHost: 'quay.io',
      username: process.env.QUAY_USERNAME,
      password: process.env.QUAY_PASSWORD,
    },
  ],
};
