import React, {useEffect} from 'react';
import {devToolsEnabled} from '../../app/flags';

import {watchAppForRelock} from './lockState';
import {RenameDialog} from './RenameDialog';
import {ShareSheet} from './ShareSheet';
import {installShellBridge} from './shellBridge';

/**
 * The share sheet and the rename dialog, mounted once above the navigator
 * so the drawer, the chat menu and the archive list can all open them.
 */
/** Debug builds: frame recorder for the drawer scroll measurement. */
function PerfProbe() {
  const {PerfProbeHost} = require('../drawer/dev/perfProbe');
  return <PerfProbeHost />;
}

export function HistoryOverlays() {
  useEffect(() => {
    watchAppForRelock();
    installShellBridge();
  }, []);
  return (
    <>
      <ShareSheet />
      <RenameDialog />
      {devToolsEnabled() ? <PerfProbe /> : null}
    </>
  );
}
