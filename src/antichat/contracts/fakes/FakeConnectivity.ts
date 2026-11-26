import {Emitter} from '../common';
import type {Connectivity} from '../connectivity';

export class FakeConnectivity extends Emitter implements Connectivity {
  online = true;
  metered = false;

  async refresh(): Promise<void> {
    this.emit();
  }

  /** Test and demo control: flip the network. */
  set(online: boolean, metered = false): void {
    this.online = online;
    this.metered = metered;
    this.emit();
  }
}
