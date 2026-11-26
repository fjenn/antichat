/**
 * Small pieces of UI state that the drawer, the chat menu and the overlays
 * share: which chat is being renamed or shared, which chats are waiting
 * out their "Undo" before they are really deleted.
 */
import {makeAutoObservable} from 'mobx';

import type {ConversationView} from '../../contracts';

class HistoryUi {
  /** Chat whose drawer row is a text field right now. */
  renamingRowId: string | null = null;
  /** Chat the rename dialog (from the chat's ••• menu) is open for. */
  renameDialogFor: ConversationView | null = null;
  /** Chat the share sheet is open for. */
  shareFor: ConversationView | null = null;
  /** Deleted, but still within their undo time: hidden from every list. */
  pendingDeleteIds: ReadonlySet<string> = new Set();

  constructor() {
    makeAutoObservable(this);
  }

  startRowRename(id: string | null): void {
    this.renamingRowId = id;
  }

  openRenameDialog(conversation: ConversationView | null): void {
    this.renameDialogFor = conversation;
  }

  openShare(conversation: ConversationView | null): void {
    this.shareFor = conversation;
  }

  setPendingDeletes(ids: ReadonlySet<string>): void {
    this.pendingDeleteIds = ids;
  }
}

export const historyUi = new HistoryUi();
