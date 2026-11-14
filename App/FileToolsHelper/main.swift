// AntiChatFileTools[Net]Slot<k>.xpc entry point (M6.T17; A-M6-T21a (a); architecture §1.2). One binary, one bundle
// per slot and variant: a `.FileTools.Net.` bundle id (and its network.client entitlement) selects the network variant.
import AntiChatFileToolsHost

FileToolsService(network: FileToolsService.isNetVariant).runForever()
