// SPDX-License-Identifier: GPL-3.0-only
import { Home } from './Home';
@Entry
@Component
struct Index {
  build() {
    Column() { Home() }.width('100%').height(LayoutPolicy.matchParent)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
  }
}
