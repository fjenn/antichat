import React, {memo} from 'react';

import {AssistantMessage} from './AssistantMessage';
import type {ThreadRow} from './ThreadController';
import {UserMessage} from './UserMessage';

/** One row of the thread. Everything it draws is in `row`. */
export const ThreadRowView = memo(function RowView({row}: {row: ThreadRow}) {
  if (row.message.role === 'user') {
    return <UserMessage message={row.message} busy={row.busy} />;
  }
  return <AssistantMessage row={row} />;
});
