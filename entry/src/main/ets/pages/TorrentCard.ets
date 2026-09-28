// SPDX-License-Identifier: GPL-3.0-only
import { TorrentRowData } from '../services/TorrentRows';
import { Torrent } from '../core/Models';
import { bytes, percent, isStopped, stateLabel } from '../core/Format';
@Component
export struct TorrentCard {
  @ObjectLink row: TorrentRowData;
  @Prop selecting: boolean = false;
  @Prop checked: boolean = false;
  onToggle: (hash: string) => void = () => {};
  onSelect: (hash: string) => void = () => {};
  onOpen: (torrent: Torrent) => void = () => {};

  build() {
    Row({ space: 12 }) {
      if (this.selecting) {
        Checkbox().select(this.checked).onChange((checked: boolean) => {
          if (checked !== this.checked) { this.onToggle(this.row.torrent.hash); }
        })
      }
      Column({ space: 8 }) {
        Text(this.row.torrent.name).fontSize(16).fontWeight(FontWeight.Medium).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('sys.color.font_primary')).width('100%')
        Row() {
          Text(stateLabel(this.row.torrent.state)).fontSize(12).fontColor($r('sys.color.font_secondary'))
          Blank()
          Text(`${percent(this.row.torrent.progress)}% · ${bytes(this.row.torrent.size)}`).fontSize(12).fontColor($r('sys.color.font_secondary'))
        }.width('100%')
        Progress({ value: percent(this.row.torrent.progress), total: 100, type: ProgressType.Linear })
          .color(isStopped(this.row.torrent.state) || this.row.torrent.progress >= 1 ? $r('sys.color.icon_tertiary') : $r('sys.color.brand'))
          .style({ strokeWidth: 2 }).width('100%')
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.arrow_down')).fontSize(12).fontColor([$r('sys.color.icon_secondary')])
          Text(bytes(this.row.torrent.dlspeed) + '/s').fontSize(12).fontColor($r('sys.color.font_secondary'))
          Blank().width(12)
          SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(12).fontColor([$r('sys.color.icon_secondary')])
          Text(bytes(this.row.torrent.upspeed) + '/s').fontSize(12).fontColor($r('sys.color.font_secondary'))
          Blank()
          Text(this.row.torrent.category).fontSize(12).maxLines(1).constraintSize({ maxWidth: '30%' })
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('sys.color.font_secondary'))
        }.width('100%')
      }.layoutWeight(1)
    }.padding(16).width('100%').borderRadius(16).backgroundColor($r('sys.color.comp_background_primary'))
      .onClick(() => { if (this.selecting) { this.onToggle(this.row.torrent.hash); } else { this.onOpen(this.row.torrent); } })
      .gesture(LongPressGesture().onAction(() => { this.onSelect(this.row.torrent.hash); }))
      .accessibilityText(`${this.row.torrent.name}，${stateLabel(this.row.torrent.state)}，${percent(this.row.torrent.progress)}%`)
  }
}
