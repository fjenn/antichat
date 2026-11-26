import '../../../testing/setup';

import React, {createRef} from 'react';
import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';

import {setPorts} from '../../../adapters';
import {shellSession} from '../../../app/session';
import {createFakePorts, type FakePorts} from '../../../contracts/fakes';
import {createMemoryEngine} from '../../../engine/memory/engine';
import {
  createChatHarness,
  type ChatHarness,
} from '../../../engine/memory/__tests__/support/memoryHarness';
import {toast, type SheetHandle} from '../../primitives';
import {DrawerProjects} from '../DrawerProjects';
import {createEngineProjectsUi} from '../engineProjectsUi';
import {createFakeProjectsUi} from '../fakeProjectsUi';
import {MoveToProjectSheet} from '../MoveToProjectSheet';
import {ProjectScreen} from '../ProjectScreen';
import {ProjectsScreen} from '../ProjectsScreen';
import {
  getProjectsUi,
  setProjectFilesSection,
  setProjectsUi,
} from '../registry';
import type {ProjectsUi} from '../types';

const navigation = {goBack: jest.fn(), navigate: jest.fn()};

describe('project screens on the fake', () => {
  let ports: FakePorts;
  let projects: ProjectsUi;

  beforeEach(() => {
    jest.clearAllMocks();
    ports = createFakePorts();
    setPorts(ports);
    projects = createFakeProjectsUi(ports.conversations);
    setProjectsUi(projects);
    shellSession.newChat();
  });

  afterEach(() => {
    cleanup();
    setProjectsUi();
    setProjectFilesSection();
    setPorts();
    toast.hide();
  });

  it('lists projects and creates one', async () => {
    render(<ProjectsScreen navigation={navigation} />);
    expect(await screen.findByText('Trip to Lisbon')).toBeTruthy();
    fireEvent.press(screen.getByTestId('projects-new'));
    fireEvent.changeText(
      await screen.findByTestId('project-create-name'),
      'Thesis',
    );
    fireEvent.press(screen.getByTestId('project-create-save'));
    expect(await screen.findByText('Thesis')).toBeTruthy();
    const created = (await projects.list()).find(p => p.name === 'Thesis')!;
    expect(navigation.navigate).toHaveBeenCalledWith('Project', {
      projectId: created.id,
    });
  });

  it('shows a project, edits its instructions and renames it', async () => {
    const [project] = (await projects.list()).filter(
      p => p.name === 'Trip to Lisbon',
    );
    render(
      <ProjectScreen
        navigation={navigation}
        route={{params: {projectId: project.id}}}
      />,
    );
    expect(await screen.findByText('Trip to Lisbon')).toBeTruthy();
    expect(
      screen.getByText('Keep answers short. Prices in euros.'),
    ).toBeTruthy();
    expect(await screen.findByTestId('project-chats-empty')).toBeTruthy();

    fireEvent.press(screen.getByTestId('project-instructions'));
    fireEvent.changeText(
      await screen.findByTestId('project-instructions-text'),
      'Answer in Portuguese.',
    );
    fireEvent.press(screen.getByTestId('project-instructions-save'));
    expect(await screen.findByText('Answer in Portuguese.')).toBeTruthy();

    act(() => {
      screen.getByTestId('project-menu').props.onPressAction({
        nativeEvent: {event: 'rename'},
      });
    });
    fireEvent.changeText(
      await screen.findByTestId('project-rename-name'),
      'Lisbon in May',
    );
    fireEvent.press(screen.getByTestId('project-rename-save'));
    expect(await screen.findByText('Lisbon in May')).toBeTruthy();
  });

  it('starts a chat in the project and lists it', async () => {
    const [project] = await projects.list();
    render(
      <ProjectScreen
        navigation={navigation}
        route={{params: {projectId: project.id}}}
      />,
    );
    fireEvent.press(await screen.findByTestId('project-new-chat'));
    await waitFor(() =>
      expect(navigation.navigate).toHaveBeenCalledWith('Main', {
        screen: 'Chat',
      }),
    );
    const chats = await projects.chats(project.id);
    expect(chats).toHaveLength(1);
    expect(shellSession.activeConversationId).toBe(chats[0].id);
    expect(
      await screen.findByTestId(`project-chat-${chats[0].id}`),
    ).toBeTruthy();
  });

  it('deletes a project with its chats', async () => {
    const [project] = await projects.list();
    const chatId = (await projects.startChat(project.id))!;
    render(
      <ProjectScreen
        navigation={navigation}
        route={{params: {projectId: project.id}}}
      />,
    );
    await screen.findByTestId('project-screen');
    act(() => {
      screen.getByTestId('project-menu').props.onPressAction({
        nativeEvent: {event: 'delete'},
      });
    });
    fireEvent.press(await screen.findByTestId('project-delete-yes'));
    await waitFor(() => expect(navigation.goBack).toHaveBeenCalled());
    await waitFor(async () =>
      expect(await projects.get(project.id)).toBeNull(),
    );
    expect(ports.conversations.get(chatId)).toBeUndefined();
  });

  it('renders the files section another milestone registers', async () => {
    const {Text} = require('react-native');
    const [project] = await projects.list();
    setProjectFilesSection(({projectId}) => <Text>files of {projectId}</Text>);
    render(
      <ProjectScreen
        navigation={navigation}
        route={{params: {projectId: project.id}}}
      />,
    );
    expect(await screen.findByText(`files of ${project.id}`)).toBeTruthy();
  });

  it('moves a chat into a project, into a new one, and out again', async () => {
    const chat = ports.conversations.conversations[0];
    const [project] = await projects.list();
    const sheet = createRef<SheetHandle>();
    const onMoved = jest.fn();
    render(
      <MoveToProjectSheet
        ref={sheet}
        conversationId={chat.id}
        onMoved={onMoved}
      />,
    );
    await act(() => sheet.current!.present());
    fireEvent.press(await screen.findByTestId(`move-to-project-${project.id}`));
    await waitFor(() => expect(onMoved).toHaveBeenCalledWith(project.id));
    expect((await projects.projectOf(chat.id))?.id).toBe(project.id);
    expect((await projects.get(project.id))?.chatCount).toBe(1);

    await act(() => sheet.current!.present());
    fireEvent.press(await screen.findByTestId('move-to-project-remove'));
    await waitFor(() => expect(onMoved).toHaveBeenCalledWith(null));
    expect(await projects.projectOf(chat.id)).toBeNull();

    await act(() => sheet.current!.present());
    fireEvent.press(await screen.findByTestId('move-to-project-new'));
    fireEvent.changeText(
      await screen.findByTestId('move-to-project-name'),
      'Reading list',
    );
    fireEvent.press(screen.getByTestId('move-to-project-create'));
    await waitFor(async () =>
      expect((await projects.projectOf(chat.id))?.name).toBe('Reading list'),
    );
  });

  it('gives the drawer its projects block', async () => {
    const onOpenProject = jest.fn();
    const onOpenAll = jest.fn();
    render(
      <DrawerProjects onOpenProject={onOpenProject} onOpenAll={onOpenAll} />,
    );
    fireEvent.press(await screen.findByText('Work notes'));
    expect(onOpenProject).toHaveBeenCalled();
    fireEvent.press(screen.getByTestId('drawer-projects-all'));
    expect(onOpenAll).toHaveBeenCalled();
  });
});

describe('project screens on the engine', () => {
  let h: ChatHarness;
  let unregister: () => void;

  beforeEach(async () => {
    h = await createChatHarness();
    const engine = createMemoryEngine({
      db: h.db,
      chats: h.chats.store,
      now: () => h.clock.now,
    });
    await engine.init();
    const ui = createEngineProjectsUi({
      projects: engine.projects,
      conversations: {
        subscribe: listener => h.chats.store.onChange(listener),
        getMeta: id => h.chats.store.getMeta(id),
      },
    });
    setProjectsUi(ui);
    unregister = () => {
      ui.dispose();
      setProjectsUi();
    };
  });

  afterEach(() => {
    cleanup();
    unregister();
    h.close();
  });

  it('creates, edits, fills and deletes a project in antichat.db', async () => {
    const ui = getProjectsUi();
    const changed = jest.fn();
    ui.subscribe(changed);
    const project = await ui.create('Lisbon', 'Prices in euros.');
    expect(project).toMatchObject({name: 'Lisbon', chatCount: 0});
    expect(changed).toHaveBeenCalled();

    await ui.update(project.id, {instructions: 'Answer in Portuguese.'});
    expect((await ui.get(project.id))?.instructions).toBe(
      'Answer in Portuguese.',
    );

    const chat = await h.addChat('Where to eat', [['Tascas?', 'Try Alfama']]);
    await ui.moveChat(chat, project.id);
    expect(await ui.chats(project.id)).toEqual([
      expect.objectContaining({id: chat, title: 'Where to eat'}),
    ]);
    expect((await ui.projectOf(chat))?.id).toBe(project.id);
    expect((await ui.get(project.id))?.chatCount).toBe(1);

    await ui.moveChat(chat, null);
    expect(await ui.chats(project.id)).toHaveLength(0);
    expect(await ui.projectOf(chat)).toBeNull();

    await ui.moveChat(chat, project.id);
    await ui.remove(project.id);
    expect(await ui.list()).toHaveLength(0);
    expect(await h.chats.store.getMeta(chat)).toBeNull();
    expect(await ui.startChat('gone')).toBeNull();
  });
});
