export const releaseVersion = '0.1.12';
export const repositoryURL = 'https://github.com/ihopefulChina/Tunnelful';
export const releaseTagURL = `${repositoryURL}/releases/tag/v${releaseVersion}`;

export const armDownloadURL =
  `${repositoryURL}/releases/download/v${releaseVersion}/Tunnelful-${releaseVersion}-arm64.dmg`;
export const intelDownloadURL =
  `${repositoryURL}/releases/download/v${releaseVersion}/Tunnelful-${releaseVersion}-x86_64.dmg`;
export const armChecksumURL = `${armDownloadURL}.sha256`;
export const intelChecksumURL = `${intelDownloadURL}.sha256`;
