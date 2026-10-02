# Wrist glance design / TASK-023

Source: user / 2026-10-02; manager/wear-continuation-20261002.json groups.band.

Palette: OLED black #000000; ink surface #161C27; Lumina blue #92ACFF; text #F3F5FC; quiet silver #A8B1C3; caution #FFD08A. Use the platform Chinese sans font, 30px target/page title, 23px body/actions, 19px secondary. Left aligned descriptions support scanning; the app title alone is centered. Large full-width touch rows, vertical scrolling, 16px horizontal safe inset and 22px top/bottom inset. No continual animation, gradients, blur, tiny icon tab bar or decorative counts.

Initial idea used five fixed bottom tabs. Review against this brief rejected it: small band screens cannot offer five adequately sized targets, and long Chinese labels would be compressed. Revised design: Home offers four full-width navigation rows; every other page includes a 48px return-home row. The distinctive element is the three named connection layers immediately beside the selected execution target; task/command information always carries its actual data provenance.

```
Home                     Child page
 Orialis                  ‹ 首页       任务
 [mock / 缓存 / 无数据]     [same provenance]
 当前目标                 title / state
 phone / app / target     summary / local detail
 当前任务                 [remote action: 待接入]
 [任务] [指令]            ... scrollable rows
 [设备] [设置]            [返回首页]
```

Default is empty and unknown. Explicit demo mode is labelled “演示 mock” on all pages and never updates the transport cache. Restored snapshots are stale, timestamped when provided, and never imply verified business connectivity. Commands have a local detail/confirmation preview and supplied waiting/failure/result states; execution is disabled until separately integrated and accepted. Device selection is a local preview and the phone-confirmed target stays independently visible. Vibration and notifications are labelled unavailable. Dense text is summarized in list rows and expanded in local detail pages.
