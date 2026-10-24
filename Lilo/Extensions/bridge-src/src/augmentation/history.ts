import { createGapEventsFromNames, gapMethod } from '../shared/gap-event.ts';

export const historyAugmentation = {
  search: gapMethod('history', 'search'),
  getVisits: gapMethod('history', 'getVisits'),
  addUrl: gapMethod('history', 'addUrl'),
  deleteUrl: gapMethod('history', 'deleteUrl'),
  deleteRange: gapMethod('history', 'deleteRange'),
  deleteAll: gapMethod('history', 'deleteAll'),
  ...createGapEventsFromNames('history', ['onVisited', 'onVisitRemoved']),
};
