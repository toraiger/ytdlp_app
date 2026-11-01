const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '開発ビルド');
const appBuildNumber = String.fromEnvironment('APP_BUILD_NUMBER');
const appRevision = String.fromEnvironment('APP_REVISION');
const appVersionLabel =
    appBuildNumber == '' ? appVersion : '$appVersion（ビルド$appBuildNumber）';
