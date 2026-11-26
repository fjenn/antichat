// ANTICHAT: in-app sign-in sheet (connectors). No sheet in tests unless a
// test switches `isAvailable` on.
export const InAppBrowser = {
  isAvailable: jest.fn(async () => false),
  openAuth: jest.fn(async () => ({type: 'cancel'})),
  closeAuth: jest.fn(),
  open: jest.fn(async () => ({type: 'cancel'})),
  close: jest.fn(),
};
export default InAppBrowser;
