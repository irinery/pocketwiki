import { userInfo } from 'node:os';

export function isolatedEnvironment(home, environment = process.env) {
  // Resolve the effective OS user, never the caller-supplied USER/LOGNAME.
  // XcodeGen requires USER even when HOME is isolated.
  const username = userInfo().username;
  if (!username) throw new Error('current OS username unavailable');
  return { PATH: environment.PATH || '/usr/bin:/bin', HOME: home, TMPDIR: '/tmp', CI: '1', POCKETWIKI_SIGN_MODE: 'adhoc', USER: username, LOGNAME: username };
}
