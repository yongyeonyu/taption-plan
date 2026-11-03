extension StickerCatalog {
    static let todoParts = #"""
    todo.ring|A l 12 86.0 50.0 85.7 54.7 84.8 59.3 83.3 63.8 81.2 68.0 78.6 71.9 75.5 75.5 71.9 78.6 68.0 81.2 63.8 83.3 59.3 84.8 54.7 85.7 50.0 86.0 45.3 85.7 40.7 84.8 36.2 83.3 32.0 81.2 28.1 78.6 24.5 75.5 21.4 71.9 18.8 68.0 16.7 63.8 15.2 59.3 14.3 54.7 14.0 50.0 14.3 45.3 15.2 40.7 16.7 36.2 18.8 32.0 21.4 28.1 24.5 24.5 28.1 21.4 32.0 18.8 36.2 16.7 40.7 15.2 45.3 14.3 50.0 14.0 54.7 14.3 59.3 15.2 63.8 16.7 68.0 18.8 71.9 21.4 75.5 24.5 78.6 28.1 81.2 32.0 83.3 36.2 84.8 40.7 85.7 45.3 86.0 50.0
    todo.ears|A p 4 12 42 14 8 44 24;A p 4 88 42 86 8 56 24
    todo.cal|A b 12 20 76 70 12;k! l 3.5 13 42 87 42;A b 27 10 9 20 4.5;A b 64 10 9 20 4.5
    todo.clock|A o 50 52 38;k! l 6 50 30 50 52 66 62
    todo.bell|A o 50 84 9;A o 50 14 6;A s M50 14 C70 14 74 32 74 46 C74 62 84 66 86 76 L14 76 C16 66 26 62 26 46 C26 32 30 14 50 14 Z
    todo.alarm|A l 7 30 80 20 90;A l 7 70 80 80 90;A e 24 24 15 10 -40;A e 76 24 15 10 40;A o 50 54 34;k! l 6 50 34 50 54 62 62
    todo.person|A o 50 32 20;A s M16 90 C16 64 32 56 50 56 C68 56 84 64 84 90 Z
    todo.arrow|A l 14 12 50 78 50;A l 14 54 24 82 50 54 76
    todo.flagnum|A l 6 22 10 22 90;A p 4 24 12 88 12 74 36 88 60 24 60
    todo.tag|A b 8 28 84 44 14
    todo.page|A b 18 10 64 80 10
    todo.drop|A s M50 10 C50 10 80 44 80 62 C80 80 66 92 50 92 C34 92 20 80 20 62 C20 44 50 10 50 10 Z
    todo.repeat|A q 11 20 46 22 18 50 18;A q 11 50 18 70 18 78 34;A p 3 62 36 94 30 84 60;A q 11 80 54 78 82 50 82;A q 11 50 82 30 82 22 66;A p 3 38 64 6 70 16 40
    todo.pill|A b 12 33 76 34 17;k! l 3.5 50 33 50 67
    """#

    static let studyParts = #"""
    study.pencil|D b 72 37 20 26 8;E b 68 35 10 30 3;A b 30 37 42 26 2;B p 3 34 37 34 63 8 50;k! o 13 50 4;k! l 2.4 34 46 67 46;k! l 2.4 34 54 67 54
    study.sharp|T b 84 44 8 12 3;T b 28 40 58 20 7;T p 3 32 40 32 60 14 50;k l 3 14 50 8 50;k! l 3 40 40 40 60;k! l 3 46 40 46 60;k! l 3 60 45 80 45
    study.ruler|A b 8 32 84 36 6;k! l 3 18 32 18 44;k! l 3 30 32 30 50;k! l 3 42 32 42 44;k! l 3 54 32 54 50;k! l 3 66 32 66 44;k! l 3 78 32 78 50
    study.eraser|pink b 12 30 76 42 11;sky b 40 28 50 46 5;k! l 2.4 52 28 52 74
    study.marker|T b 26 37 54 26 8;k b 66 37 14 26 3;T p 3 26 39 26 61 10 56 10 44;k! l 2.4 34 44 62 44
    study.pass|w o 50 50 36;@todo.ring 50 50 1 A=red;red! t 50 50 30 합격
    study.diploma|cream b 10 34 80 32 10;butter o 18 50 16;k! o 18 50 5;red b 46 30 12 40 3;red l 6 48 70 44 84;red l 6 56 70 60 84
    study.book|A b 18 10 66 80 10;k! l 3.5 31 10 31 90
    study.pen|A b 76 43 16 14 4;A b 28 38 52 24 8;A p 3 30 41 30 59 10 50;k! o 12 50 2.5;k! l 3 40 38 40 62;k! l 3 46 38 46 62;k! l 4 58 45 78 45
    study.fountain|A b 56 38 36 24 10;k b 48 38 8 24 3;A s M48 36 L48 64 C36 64 22 58 8 50 C22 42 36 36 48 36 Z;k! l 3 12 50 36 50;k! o 36 50 3.5
    study.tack|A b 34 10 32 13 6;A p 3 40 23 60 23 66 46 34 46;A b 22 44 56 13 6;k l 3 50 60 50 88
    study.band|A l 7 88.0 50.0 87.5 53.4 86.1 56.8 83.9 60.0 80.7 62.9 76.9 65.6 72.3 67.8 67.3 69.6 61.7 70.9 55.9 71.7 50.0 72.0 44.1 71.7 38.3 70.9 32.7 69.6 27.7 67.8 23.1 65.6 19.3 62.9 16.1 60.0 13.9 56.8 12.5 53.4 12.0 50.0 12.5 46.6 13.9 43.2 16.1 40.0 19.3 37.1 23.1 34.4 27.7 32.2 32.7 30.4 38.3 29.1 44.1 28.3 50.0 28.0 55.9 28.3 61.7 29.1 67.3 30.4 72.3 32.2 76.9 34.4 80.7 37.1 83.9 40.0 86.1 43.2 87.5 46.6 88.0 50.0
    study.crayon|A b 34 26 36 60 6;A p 3 40 28 64 28 52 8;B b 30 42 44 34 3;k! q 2.6 34 54 52 60 70 54;k! q 2.6 34 64 52 70 70 64
    study.brush|tan b 44 40 48 16 8;gray b 32 37 16 22 3;C s M34 36 L34 60 C24 64 14 58 8 50 C14 42 24 36 34 36 Z
    study.tube|A p 4 28 42 72 42 66 14 34 14;A b 26 42 48 42 8;gray b 40 82 20 10 3;k! b 34 52 32 20 4
    """#

    static let todoSource = #"""
    todo.box.empty|빈 체크박스|Empty box|m|T b 14 14 72 72 16
    todo.box.check|체크박스|Checked box|m|T b 14 14 72 72 16;k! l 9 30 52 44 66 70 34
    todo.box.x|X 체크박스|Crossed box|m|T b 14 14 72 72 16;k! l 9 33 33 67 67;k! l 9 67 33 33 67
    todo.box.dash|하다 만 칸|Half done box|m|T b 14 14 72 72 16;k! l 9 32 50 68 50
    todo.box.big|크게 체크|Big check|m|T b 10 26 64 64 14;k l 7 28 56 44 72 86 18
    todo.box.paw|발바닥 체크|Paw check|m|@todo.ears 50 50 1 A=T;T b 14 18 72 70 16;@paw 50 54 0.6 A=k
    todo.mark.check|체크 표시|Check mark|m|T l 15 16 52 40 76 84 24
    todo.mark.x|X 표시|Cross mark|m|T l 15 20 20 80 80;T l 15 80 20 20 80
    todo.mark.ok|동그라미 표시|Circle mark|m|@todo.ring 50 50 1.05 A=T
    todo.list|체크리스트|Checklist|m|@todo.page 50 50 1 A=T;k! l 4 28 28 33 33 42 22;k! l 5 50 28 72 28;k! l 4 28 50 33 55 42 44;k! l 5 50 50 72 50;k! l 4 28 72 33 77 42 66;k! l 5 50 72 72 72
    todo.clipboard|클립보드|Clipboard|m|T b 16 16 68 76 10;T b 34 8 32 18 6;k! l 5 30 44 70 44;k! l 5 30 58 70 58;k! l 5 30 72 56 72
    todo.cal|달력|Calendar|m|@todo.cal 50 50 1 A=T;k! o 30 56 4;k! o 50 56 4;k! o 70 56 4;k! o 30 74 4;k! o 50 74 4;k! o 70 74 4
    todo.cal.star|별 달력|Star calendar|m|@todo.cal 50 50 1 A=T;k! star 50 66 19 9 5
    todo.cal.heart|기념일 달력|Heart calendar|m|@todo.cal 50 50 1 A=T;k! heart 50 66 30
    todo.cal.cat|고양이 달력|Cat calendar|m|@todo.ears 50 50 1 A=T;T b 12 22 76 68 14;k! l 3.5 13 42 87 42;@paw 50 66 0.5 A=k
    todo.dday|D-DAY 달력|D-day|m|@todo.cal 50 50 1 A=T;k! t 50 66 19 D-DAY
    todo.dday.1|D-1 달력|D-1|m|@todo.cal 50 50 1 A=T;k! t 50 66 30 D-1
    todo.dday.7|D-7 달력|D-7|m|@todo.cal 50 50 1 A=T;k! t 50 66 30 D-7
    todo.dday.30|D-30 달력|D-30|m|@todo.cal 50 50 1 A=T;k! t 50 66 26 D-30
    todo.clock|시계|Clock|m|@todo.clock 50 48 1.08 A=T
    todo.clock.cat|고양이 시계|Cat clock|m|@todo.ears 50 50 1 A=T;@todo.clock 50 50 1 A=T
    todo.alarm|알람|Alarm clock|m|@todo.alarm 50 50 1 A=T
    todo.alarm.ring|울리는 알람|Ringing alarm|c|red l 5 8 50 12 42;red l 5 92 50 88 42;@todo.alarm 50 50 0.92 A=butter
    todo.hourglass|모래시계|Hourglass|m|T s M28 18 L72 18 C72 40 56 44 56 50 C56 56 72 60 72 82 L28 82 C28 60 44 56 44 50 C44 44 28 40 28 18 Z;k! p 3 36 78 64 78 50 62;k! p 3 40 30 60 30 50 42;T b 20 8 60 13 6;T b 20 79 60 13 6
    todo.bell|종|Bell|m|@todo.bell 50 50 1 A=T
    todo.bell.ring|울리는 종|Ringing bell|m|T q 6 12 30 6 44 12 58;T q 6 88 30 94 44 88 58;@todo.bell 50 50 0.82 A=T
    todo.star|중요|Important|m|T star 50 52 44 24 5;k! t 50 54 34 !
    todo.exclaim|느낌표|Exclamation|m|T b 37 8 26 58 13;T o 50 80 12
    todo.exclaim.two|느낌표 둘|Double exclamation|m|T b 16 8 26 58 13;T o 29 80 12;T b 58 8 26 58 13;T o 71 80 12
    todo.question|물음표|Question|m|T q 15 28 34 30 14 52 14;T q 15 52 14 76 16 72 36;T q 15 72 36 68 46 50 54;T l 15 50 54 50 60;T o 50 82 11
    todo.flag|깃발 표시|Flag|m|T l 6 24 10 24 90;T p 4 27 12 84 32 27 54
    todo.flag.finish|마감 깃발|Finish flag|m|T l 6 18 10 18 90;T b 22 12 66 44 4;k! b 22 12 16.5 14.7 1;k! b 55 12 16.5 14.7 1;k! b 38.5 26.7 16.5 14.7 1;k! b 71.5 26.7 16.5 14.7 1;k! b 22 41.3 16.5 14.7 1;k! b 55 41.3 16.5 14.7 1
    todo.appointment|약속|Appointment|m|T p 3 38 62 62 62 50 92;T o 50 38 30;k! l 5.5 50 22 50 38 62 46
    todo.meeting|미팅|Meeting|m|@todo.person 26 66 0.54 A=T;@todo.person 74 66 0.54 A=T;T b 30 8 40 22 10;T p 3 44 26 56 26 50 36;k! o 41 19 2.6;k! o 50 19 2.6;k! o 59 19 2.6
    todo.conference|회의|Conference|m|@todo.person 22 42 0.5 A=T;@todo.person 78 42 0.5 A=T;@todo.person 50 38 0.56 A=T;T b 8 62 84 16 7;T l 6 22 78 22 90;T l 6 78 78 78 90
    todo.phone|전화|Phone|m|T s M24 12 L36 10 C40 10 42 13 43 16 L47 30 C48 34 46 37 43 39 L37 44 C42 54 48 60 58 64 L62 58 C64 55 67 53 71 54 L85 58 C88 59 90 62 90 65 L88 78 C86 86 79 90 72 90 C38 88 10 60 10 28 C10 20 16 13 24 12 Z
    todo.mail|메일|Mail|m|T b 8 22 84 58 11;k! l 4 11 28 50 56 89 28
    todo.mail.new|새 메일|New mail|m|T b 8 28 76 54 11;k! l 4 11 34 46 60 81 34;T o 78 26 14;k! t 78 27 20 1
    todo.work|출근 가방|Work bag|m|T l 7 36 32 36 18 64 18 64 32;T b 8 30 84 56 12;k! l 4 8 56 92 56;T b 42 49 16 13 4
    todo.home|퇴근|Off work|m|T b 12 10 42 80 7;k! o 44 52 4;T l 11 62 50 78 50;T l 11 68 34 86 50 68 66
    todo.overtime|야근|Overtime|m|T s M86 6 C72 6 62 16 62 28 C62 40 74 50 88 44 C78 44 72 36 72 26 C72 16 78 8 86 6 Z;T b 18 36 46 34 5;T b 8 72 66 13 6;k! l 3.5 28 46 54 46;k! l 3.5 28 54 48 54;k! l 3.5 28 62 38 62
    todo.vacation|휴가|Vacation|c|yellow o 18 22 10;butter e 50 84 42 9;choco l 6 52 28 52 80;red s M14 48 C16 8 88 8 90 48 C78 38 64 38 52 48 C40 38 26 38 14 48 Z
    todo.hospital|병원 예약|Clinic visit|m|@todo.cal 50 50 1 A=T;k! l 9 50 54 50 78;k! l 9 38 66 62 66
    todo.birthday|생일 알림|Birthday|c|sky b 44 22 9 28 3;orange s M48.5 6 C56 14 56 22 48.5 22 C41 22 41 14 48.5 6 Z;cream b 12 46 72 44 10;rose s M12 56 C12 48 18 46 22 46 L74 46 C80 46 84 48 84 56 C84 66 74 66 72 58 C70 68 60 68 58 58 C56 68 44 68 42 58 C40 68 28 68 26 58 C24 66 12 66 12 56 Z;@todo.bell 80 22 0.3 A=yellow
    todo.reminder|잊지 말기|Don't forget|c|peach b 36 8 28 66 14;w b 42 12 16 16 7;peach b 16 54 68 38 15;k! l 2.4 30 60 30 72;k! l 2.4 70 60 70 72;red b 33 36 34 10 4;red e 80 30 12 8 -25;red e 80 50 12 8 25;red o 68 41 7
    todo.arrow.right|오른쪽 화살표|Right arrow|m|@todo.arrow 50 50 1 A=T
    todo.arrow.left|왼쪽 화살표|Left arrow|m|@todo.arrow 50 50 1 180 A=T
    todo.arrow.up|위 화살표|Up arrow|m|@todo.arrow 50 50 1 -90 A=T
    todo.arrow.down|아래 화살표|Down arrow|m|@todo.arrow 50 50 1 90 A=T
    todo.arrow.upright|오른쪽 위 화살표|Up-right arrow|m|@todo.arrow 50 50 1 -45 A=T
    todo.arrow.downright|오른쪽 아래 화살표|Down-right arrow|m|@todo.arrow 50 50 1 45 A=T
    todo.arrow.both|양쪽 화살표|Both ways|m|T l 13 14 50 86 50;T l 13 32 28 12 50 32 72;T l 13 68 28 88 50 68 72
    todo.arrow.turn|돌아가기 화살표|Turn back|m|T q 13 78 80 90 28 48 28;T l 13 48 28 24 28;T l 13 40 10 20 28 40 46
    todo.repeat|반복|Repeat|m|@todo.repeat 50 50 1 A=T
    todo.progress.0|진행 0%|Progress 0|m|T b 8 18 84 64 13;k! t 50 38 26 0%;T b 16 56 68 16 8
    todo.progress.25|진행 25%|Progress 25|m|T b 8 18 84 64 13;k! t 50 38 26 25%;T b 16 56 68 16 8;k! b 18 58 14 12 6
    todo.progress.50|진행 50%|Progress 50|m|T b 8 18 84 64 13;k! t 50 38 26 50%;T b 16 56 68 16 8;k! b 18 58 32 12 6
    todo.progress.75|진행 75%|Progress 75|m|T b 8 18 84 64 13;k! t 50 38 26 75%;T b 16 56 68 16 8;k! b 18 58 48 12 6
    todo.progress.100|진행 100%|Progress 100|m|T b 8 18 84 64 13;k! t 50 38 26 100%;T b 16 56 68 16 8;k! b 18 58 64 12 6
    todo.priority.1|우선순위 1|Priority 1|m|@todo.flagnum 50 50 1 A=T;k! t 52 36 36 1
    todo.priority.2|우선순위 2|Priority 2|m|@todo.flagnum 50 50 1 A=T;k! t 52 36 36 2
    todo.priority.3|우선순위 3|Priority 3|m|@todo.flagnum 50 50 1 A=T;k! t 52 36 36 3
    todo.number.1|번호 1|Number 1|m|T b 14 14 72 72 16;k! t 50 52 52 1
    todo.number.2|번호 2|Number 2|m|T b 14 14 72 72 16;k! t 50 52 52 2
    todo.number.3|번호 3|Number 3|m|T b 14 14 72 72 16;k! t 50 52 52 3
    todo.number.4|번호 4|Number 4|m|T b 14 14 72 72 16;k! t 50 52 52 4
    todo.number.5|번호 5|Number 5|m|T b 14 14 72 72 16;k! t 50 52 52 5
    todo.lock|잠금|Lock|m|T l 9 32 46 32 30 38 18 50 13 62 18 68 30 68 46;T b 16 42 68 48 12;k! o 50 62 6.5;k! l 5 50 62 50 76
    todo.unlock|잠금 해제|Unlocked|m|T l 9 32 46 32 26 38 14 50 10 62 14 68 24;T b 16 42 68 48 12;k! o 50 62 6.5;k! l 5 50 62 50 76
    todo.key|열쇠|Key|m|T l 11 44 44 84 84;T l 9 64 64 74 54;T l 9 76 76 86 66;T o 30 30 22;k! o 26 26 7
    todo.pill|약 먹기|Take medicine|m|@todo.pill 50 50 1 -40 A=T
    todo.pill.box|약 먹기 칸|Medicine check|m|T b 10 10 80 80 16;@todo.pill 50 50 0.7 -40 A=T
    todo.water|물 마시기|Drink water|m|@todo.drop 50 50 1 A=T;k! q 4 34 62 34 76 48 80
    todo.water.habit|물 마시기 칸|Water tracker|m|T b 8 14 84 72 14;@todo.drop 24 34 0.25 A=k;@todo.drop 41 34 0.25 A=k;@todo.drop 59 34 0.25 A=k;@todo.drop 76 34 0.25 A=T;@todo.drop 24 65 0.25 A=T;@todo.drop 41 65 0.25 A=T;@todo.drop 59 65 0.25 A=T;@todo.drop 76 65 0.25 A=T
    todo.habit.grid|습관 트래커|Habit tracker|m|T b 8 14 84 72 12;k! o 24 32 6.5;k! o 41 32 6.5;k! o 59 32 6.5;T o 76 32 6;k! o 24 50 6.5;T o 41 50 6;k! o 59 50 6.5;T o 76 50 6;T o 24 68 6;T o 41 68 6;T o 59 68 6;T o 76 68 6
    todo.habit.week|일주일 칸|Week tracker|m|T b 6 34 88 32 8;k! l 3 18.6 34 18.6 66;k! l 3 31.1 34 31.1 66;k! l 3 43.7 34 43.7 66;k! l 3 56.3 34 56.3 66;k! l 3 68.9 34 68.9 66;k! l 3 81.4 34 81.4 66;k! o 12.3 50 4;k! o 24.9 50 4;k! o 37.4 50 4
    todo.word.today|오늘|Today|m|@todo.tag 50 50 1 A=T;k! t 50 50 30 오늘
    todo.word.tomorrow|내일|Tomorrow|m|@todo.tag 50 50 1 A=T;k! t 50 50 30 내일
    todo.word.done|완료|Done|m|@todo.tag 50 50 1 A=T;k! t 50 50 30 완료
    todo.word.must|필수|Must do|m|@todo.tag 50 50 1 A=T;k! t 50 50 30 필수
    todo.word.cancel|취소|Canceled|m|@todo.tag 50 50 1 A=T;k! t 50 50 30 취소
    todo.word.later|나중에|Later|m|@todo.tag 50 50 1 A=T;k! t 50 50 26 나중에
    """#

    static let studySource = #"""
    study.book|책|Book|m|@study.book 50 50 1 A=T;k! b 42 26 30 12 3
    study.book.cat|고양이 책|Cat book|m|T p 4 20 26 22 6 44 18;T p 4 82 26 80 6 58 18;T b 18 14 66 76 10;k! l 3.5 31 14 31 90;@paw 57 52 0.42 A=k
    study.book.open|펼친 책|Open book|m|T s M50 28 C40 16 20 16 8 22 L8 80 C20 74 40 74 50 86 Z;T s M50 28 C60 16 80 16 92 22 L92 80 C80 74 60 74 50 86 Z;k! l 3.5 18 36 40 40;k! l 3.5 18 50 40 54;k! l 3.5 82 36 60 40;k! l 3.5 82 50 60 54
    study.book.stack|책 더미|Stack of books|c|blue b 12 66 76 22 6;w! b 70 71 18 12 3;yellow b 20 42 66 22 6;w! b 20 47 16 12 3;rose b 14 18 64 22 6;w! b 62 23 16 12 3
    study.pencil|연필|Pencil|c|@study.pencil 50 50 1 -45 A=yellow B=peach D=rose E=gray
    study.pencil.mono|한 색 연필|Pencil|m|@study.pencil 50 50 1 -45 A=T B=T D=T E=T
    study.sharp|샤프|Mechanical pencil|m|@study.sharp 50 50 1 -45
    study.eraser|지우개|Eraser|c|@study.eraser 50 50 1 -18
    study.ruler|자|Ruler|m|@study.ruler 50 50 1 -30 A=T
    study.notebook|공책|Notebook|m|T b 22 10 62 80 8;k! l 3.5 36 32 74 32;k! l 3.5 36 48 74 48;k! l 3.5 36 64 74 64;k l 3 14 22 28 22;k l 3 14 40 28 40;k l 3 14 58 28 58;k l 3 14 76 28 76
    study.laptop|노트북|Laptop|m|T b 18 16 64 50 7;T p 3 18 66 82 66 92 84 8 84;@paw 50 40 0.42 A=k;k! l 3.5 42 75 58 75
    study.calculator|계산기|Calculator|m|T b 22 8 56 84 11;k! b 30 16 40 18 3;k! o 35 46 4.5;k! o 50 46 4.5;k! o 65 46 4.5;k! o 35 62 4.5;k! o 50 62 4.5;k! o 65 62 4.5;k! o 35 78 4.5;k! o 50 78 4.5;k! o 65 78 4.5
    study.glasses|안경|Glasses|m|T l 6 8 48 12 34;T l 6 92 48 88 34;T q 6 42 48 50 42 58 48;@todo.ring 27 52 0.54 A=T;@todo.ring 73 52 0.54 A=T
    study.cap|학사모|Graduation cap|c|navy s M24 44 L24 70 C34 82 66 82 76 70 L76 44 Z;navy p 3 50 18 94 40 50 62 6 40;yellow l 4 50 40 84 46 84 70;yellow b 79 68 10 16 4
    study.exam|A+ 시험지|Top marks|c|w b 16 10 68 80 8;gray! l 3.5 28 62 72 62;gray! l 3.5 28 74 72 74;red! t 50 36 42 A+
    study.score100|100점|Perfect score|c|w b 8 14 84 72 14;red! t 50 40 40 100;red! q 5 18 64 50 72 82 60;red! q 5 24 76 50 82 76 72
    study.board|칠판|Chalkboard|c|tan b 8 12 84 64 6;#3E7A62 b 15 19 70 50 3;w! t 50 44 24 1+1=2;tan l 6 26 76 18 92;tan l 6 74 76 82 92;w b 56 70 18 7 2
    study.backpack|책가방|Backpack|d|red p 4 24 26 28 8 42 18;red p 4 76 26 72 8 58 18;red b 18 16 64 74 20;orange b 28 54 44 28 8;k! l 3 28 66 72 66;w o 50 66 4
    study.globe|지구본|Globe|d|choco b 30 82 40 10 5;choco q 6 22 18 6 52 44 80;blue o 50 42 32;green! s M34 22 C44 16 54 22 50 32 C46 40 36 40 30 36 C26 30 28 24 34 22 Z;green! s M58 42 C68 38 78 44 74 54 C70 64 60 66 56 58 C54 50 54 46 58 42 Z
    study.microscope|현미경|Microscope|m|T b 18 78 64 13 6;T q 10 72 80 92 50 62 26;T b 24 60 38 9 4;T b 36 8 18 16 4 -25;T b 34 18 22 34 5 -25;T b 26 48 12 12 3 -25
    study.flask|플라스크|Flask|c|w b 34 8 32 11 5;w s M41 18 L59 18 L59 38 L82 78 C86 86 80 90 74 90 L26 90 C20 90 14 86 18 78 L41 38 Z;mint! s M31 60 L69 60 L78 79 C80 84 76 86 72 86 L28 86 C24 86 20 84 22 79 Z;w! o 42 72 4;w! o 58 66 3;w! o 58 78 2.5
    study.math|수학 기호|Math symbols|m|T b 10 10 80 80 16;k! l 7 21 33 43 33;k! l 7 32 22 32 44;k! l 7 57 33 79 33;k! l 7 23 59 41 77;k! l 7 41 59 23 77;k! l 6 57 68 79 68;k! o 68 58 4;k! o 68 78 4
    study.pi|파이|Pi|m|T l 13 16 26 84 26;T l 13 36 26 34 78;T q 13 66 26 62 78 80 76
    study.sqrt|루트|Square root|m|T l 11 10 58 24 50 40 84 56 18 90 18
    study.abc|영어 ABC|ABC|m|T b 8 24 84 52 14;k! t 50 50 38 ABC
    study.korean|한글 가나다|Korean|m|T b 8 24 84 52 14;k! t 50 50 30 가나다
    study.note|음표|Music note|m|T l 8 40 72 40 22 82 12 82 64;T e 28 74 15 11 -15;T e 70 66 15 11 -15
    study.coffee|벼락치기 커피|Cram coffee|m|T l 9 70 44 86 44 86 66 70 66;T b 14 26 60 64 12;k! p 3 50 34 32 62 44 62 38 82 58 54 46 54;T q 5 30 18 24 12 30 6;T q 5 54 18 48 12 54 6
    study.stopwatch|스톱워치|Stopwatch|m|T b 42 6 16 11 4;T b 46 14 8 10 2;T b 76 18 14 9 3 40;T o 50 56 36;k! l 6 50 56 62 38;k! o 50 56 4
    study.highlighter|형광펜|Highlighter|m|T b 8 76 62 13 6;@study.marker 56 40 1 -45
    study.pass|합격 도장|Passed stamp|c|@study.pass 50 50 1.08 -12
    study.diploma|졸업장|Diploma|c|@study.diploma 50 50 1 -20
    study.idea|전구 아이디어|Bright idea|d|yellow l 5 10 42 16 42;yellow l 5 90 42 84 42;yellow l 5 20 14 25 19;yellow l 5 80 14 75 19;gray b 39 68 22 22 6;yellow s M50 12 C68 12 78 26 78 40 C78 54 66 60 64 72 L36 72 C34 60 22 54 22 40 C22 26 32 12 50 12 Z;k! l 3 42 80 58 80
    study.library|도서관|Library|m|T p 3 50 8 92 34 8 34;T b 18 38 13 38 3;T b 43.5 38 13 38 3;T b 69 38 13 38 3;T b 10 76 80 14 4;k! p 3 50 24 38 19 38 28 50 31;k! p 3 50 24 62 19 62 28 50 31
    study.shelf|책장|Bookshelf|c|choco b 10 10 80 80 6;cream! b 16 15 68 33 2;cream! b 16 52 68 33 2;red b 21 20 10 28 2;blue b 33 16 10 32 2;yellow b 45 22 10 26 2;green b 62 18 10 30 2 8;purple b 21 58 10 27 2;mint b 33 54 10 31 2;rose b 45 60 10 25 2;orange b 62 58 18 27 2
    study.flashcard|암기 카드|Flash cards|m|T b 26 28 62 50 7 8;T b 12 24 66 54 7;k! l 5 30 42 60 42;k! l 5 30 56 50 56;k l 4 20 14 20 34;k l 4 34 14 34 34
    study.wrongnote|오답 노트|Mistake notes|c|w b 18 10 66 80 10;navy b 18 10 14 80 6;red! l 8 44 36 72 64;red! l 8 72 36 44 64
    study.dict|사전|Dictionary|m|T b 14 10 72 80 10;k! l 3.5 14 74 86 74;k! l 3.5 28 10 28 74;k! t 57 42 26 사전
    study.protractor|각도기|Protractor|m|T s M8 76 C8 8 92 8 92 76 Z;k! l 3 50 30 50 42;k! l 3 25 40 32 48;k! l 3 75 40 68 48;k! l 3 15 60 24 62;k! l 3 85 60 76 62;k! o 50 74 3.5
    study.setsquare|삼각자|Set square|m|T p 4 16 12 16 88 88 88;k! l 3 28 88 28 79;k! l 3 40 88 40 79;k! l 3 52 88 52 79;k! l 3 16 76 25 76;k! l 3 16 64 25 64;k! l 3 16 52 25 52
    study.school|학교|School|m|T l 5 50 24 50 8;T p 3 54 8 70 13 54 18;T p 3 50 22 72 44 28 44;T b 8 42 84 48 7;k! b 42 66 16 24 3;k! b 18 54 14 14 3;k! b 68 54 14 14 3
    study.apple|사과|Apple|d|choco l 5 50 26 54 12;leaf s M54 22 C58 12 70 10 76 14 C74 24 62 28 54 22 Z;red s M50 28 C60 20 84 22 84 50 C84 72 68 90 58 90 C54 90 52 88 50 88 C48 88 46 90 42 90 C32 90 16 72 16 50 C16 22 40 20 50 28 Z
    study.cat.read|책 읽는 화랑이|Reading Hwarang|d|@cat.hwarang 50 38 0.76;@face.happy 50 38 0.76;sky s M50 66 C42 60 24 60 14 64 L14 88 C24 84 42 84 50 90 Z;sky s M50 66 C58 60 76 60 86 64 L86 88 C76 84 58 84 50 90 Z
    study.cat.glasses|안경 쓴 윤복이|Yunbok in glasses|d|@cat.yunbok;@face.smile;k q 3 46 53 50 50 54 53;@todo.ring 36 54 0.32 A=k;@todo.ring 64 54 0.32 A=k
    """#

    static let stationerySource = #"""
    stationery.pen|펜|Pen|m|@study.pen 50 50 1 -45 A=T
    stationery.fountain|만년필|Fountain pen|m|@study.fountain 50 50 1 -45 A=T
    stationery.tape.roll|마스킹테이프|Masking tape|m|T p 3 54 66 92 66 86 72 92 78 86 84 92 90 54 90;T l 20 73.0 46.0 72.8 49.5 72.1 53.0 70.9 56.3 69.4 59.5 67.4 62.4 65.1 65.1 62.4 67.4 59.5 69.4 56.3 70.9 53.0 72.1 49.5 72.8 46.0 73.0 42.5 72.8 39.0 72.1 35.7 70.9 32.5 69.4 29.6 67.4 26.9 65.1 24.6 62.4 22.6 59.5 21.1 56.3 19.9 53.0 19.2 49.5 19.0 46.0 19.2 42.5 19.9 39.0 21.1 35.7 22.6 32.5 24.6 29.6 26.9 26.9 29.6 24.6 32.5 22.6 35.7 21.1 39.0 19.9 42.5 19.2 46.0 19.0 49.5 19.2 53.0 19.9 56.3 21.1 59.5 22.6 62.4 24.6 65.1 26.9 67.4 29.6 69.4 32.5 70.9 35.7 72.1 39.0 72.8 42.5 73.0 46.0;k! l 3 60 68 60 88
    stationery.tape.plain|테이프 조각|Tape strip|m|T p 3 8 34 14 42 8 50 14 58 8 66 92 66 86 58 92 50 86 42 92 34
    stationery.tape.stripe|줄무늬 테이프|Striped tape|m|T p 3 8 34 14 42 8 50 14 58 8 66 92 66 86 58 92 50 86 42 92 34;k! l 4 28 37 20 63;k! l 4 44 37 36 63;k! l 4 60 37 52 63;k! l 4 76 37 68 63
    stationery.tape.dots|물방울 테이프|Dotted tape|c|butter p 3 8 34 14 42 8 50 14 58 8 66 92 66 86 58 92 50 86 42 92 34;red! o 26 43 4;red! o 44 57 4;red! o 62 43 4;red! o 78 57 4
    stationery.tape.hearts|하트 테이프|Heart tape|c|pink p 3 8 34 14 42 8 50 14 58 8 66 92 66 86 58 92 50 86 42 92 34;red! heart 30 49 15;red! heart 52 49 15;red! heart 74 49 15
    stationery.scissors|가위|Scissors|m|T s M42 70 L56 62 L84 8 Z;T s M58 70 L44 62 L16 8 Z;@todo.ring 30 76 0.38 A=T;@todo.ring 70 76 0.38 A=T;k! o 50 52 3.5
    stationery.glue|풀|Glue stick|m|T b 34 8 32 26 6;T b 28 32 44 60 8;k! t 50 62 30 풀
    stationery.clip|클립|Paper clip|m|T l 6 58 34 58 66 54 74 48 76 42 72 40 66 40 24 44 14 54 10 64 14 68 24 68 72 62 84 50 90 36 84 30 72 30 36
    stationery.stapler|스테이플러|Stapler|m|T b 10 70 80 16 6;T b 16 60 14 16 4;T s M12 58 C10 44 20 36 32 34 L82 28 C90 28 92 34 92 40 C92 48 88 50 82 50 L20 62 C16 64 12 62 12 58 Z;k l 3 78 52 78 68
    stationery.binderclip|집게|Binder clip|m|T l 6 36 52 26 30 30 14 70 14 74 30 64 52;T p 3 28 44 72 44 88 88 12 88;k! l 3 24 56 76 56
    stationery.tack|압정|Push pin|m|@study.tack 50 50 1 25 A=T
    stationery.band|고무줄|Rubber band|m|@study.band 50 50 1 -30 A=T;@study.band 50 50 1 30 A=T
    stationery.postit|포스트잇|Sticky note|m|T p 3 12 12 88 12 88 66 66 88 12 88;k! l 3 66 87 66 66 87 66
    stationery.postit.lines|글 쓴 포스트잇|Written note|m|T p 3 12 12 88 12 88 66 66 88 12 88;k! l 3 66 87 66 66 87 66;k! l 4.5 26 30 74 30;k! l 4.5 26 46 74 46;k! l 4.5 26 62 54 62
    stationery.postit.heart|하트 포스트잇|Heart note|m|T p 3 12 12 88 12 88 66 66 88 12 88;k! l 3 66 87 66 66 87 66;k! heart 46 46 34
    stationery.memopad|떡메모지|Memo pad|m|T b 20 28 68 60 5;T b 16 22 68 60 5;T b 12 16 68 60 5;k! b 12 16 68 11 4;k! l 3.5 22 42 70 42;k! l 3.5 22 56 56 56
    stationery.tabs|인덱스 탭|Index tabs|c|rose b 66 12 26 18 5;sky b 66 36 26 18 5;butter b 66 60 26 18 5;w b 10 8 68 84 6;gray! l 3.5 22 28 64 28;gray! l 3.5 22 44 64 44;gray! l 3.5 22 60 54 60
    stationery.stamp|스탬프|Stamp|m|T o 50 20 13;T b 42 28 16 22 4;T b 20 46 60 18 7;T b 14 62 72 14 4;k l 3 26 88 74 88
    stationery.inkpad|잉크패드|Ink pad|m|T b 8 24 84 60 10;k! b 16 32 68 44 6;@paw 50 54 0.56 A=T
    stationery.envelope|편지 봉투|Envelope|c|cream b 8 22 84 58 9;k! l 3 11 28 50 56 89 28;red heart 50 54 20
    stationery.postage|우표|Postage stamp|m|T b 16 10 68 80 2;k! o 16 20 3;k! o 16 32 3;k! o 16 44 3;k! o 16 56 3;k! o 16 68 3;k! o 16 80 3;k! o 84 20 3;k! o 84 32 3;k! o 84 44 3;k! o 84 56 3;k! o 84 68 3;k! o 84 80 3;k! o 28 10 3;k! o 40 10 3;k! o 50 10 3;k! o 60 10 3;k! o 72 10 3;k! o 28 90 3;k! o 40 90 3;k! o 50 90 3;k! o 60 90 3;k! o 72 90 3;@paw 50 50 0.6 A=k
    stationery.diary|다이어리|Diary|m|T p 3 62 84 74 84 74 92 68 88 62 92;T p 4 20 30 22 6 44 18;T p 4 84 30 82 6 60 18;T b 18 14 66 72 11;k! b 72 40 12 16 3;k! heart 46 48 28
    stationery.binder|바인더|Binder|m|T b 16 8 68 84 8;k! b 16 8 16 84 6;k! b 46 24 28 34 3;T o 24 74 4
    stationery.pouch|필통|Pencil case|m|T b 26 8 12 40 3 -10;T b 44 6 12 40 3;T b 62 8 12 40 3 10;T b 8 32 84 54 18;k! l 4 18 48 82 48;k! o 82 48 5;k! l 3 82 48 82 60
    stationery.ruler|긴 자|Long ruler|m|@study.ruler 50 50 1 A=T
    stationery.compass|컴퍼스|Compass|m|T b 45 6 10 16 4;T l 7 50 24 26 80;T l 7 50 24 74 72;T b 69 70 11 12 3;k l 3 75 84 75 90;k l 3 26 84 26 90;T o 50 24 9
    stationery.colorpencil|색연필|Colored pencils|c|@study.pencil 22 50 0.8 80 A=red B=peach D=red E=gray;@study.pencil 50 50 0.8 90 A=yellow B=peach D=yellow E=gray;@study.pencil 78 50 0.8 100 A=blue B=peach D=blue E=gray
    stationery.crayon|크레용|Crayon|c|@study.crayon 22 50 0.66 A=red B=cream;@study.crayon 50 50 0.66 A=yellow B=cream;@study.crayon 78 50 0.66 A=blue B=cream
    stationery.crayon.mono|한 색 크레용|Crayon|m|@study.crayon 50 50 1.05 20 A=T B=T
    stationery.tube|물감|Paint tube|c|w p 3 18 14 82 14 72 64 28 64;w p 3 28 64 72 64 60 76 40 76;blue b 40 74 20 14 3;blue! b 29 30 42 22 3;gray b 14 8 72 9 3
    stationery.palette|팔레트|Palette|c|tan s M50 12 C78 12 92 32 92 50 C92 62 84 68 74 66 C64 64 58 68 60 76 C62 86 54 90 46 88 C24 86 8 70 8 50 C8 30 26 12 50 12 Z;red! o 30 36 7;yellow! o 52 28 7;green! o 72 40 7;blue! o 24 58 7
    stationery.brush|붓|Paint brush|c|@study.brush 50 50 1 -45 C=rose
    stationery.sketchbook|스케치북|Sketchbook|m|T b 12 20 76 70 6;k l 3 24 12 24 28;k l 3 38 12 38 28;k l 3 50 12 50 28;k l 3 62 12 62 28;k l 3 76 12 76 28;k! o 66 46 6;k! l 4 22 78 40 52 54 70 62 62 78 78
    stationery.bookmark|책갈피|Bookmark|m|T q 4 50 8 66 2 62 14;T p 3 28 10 72 10 72 92 50 76 28 92;k! heart 50 38 26
    stationery.label|라벨|Label|m|T p 5 8 50 28 24 92 24 92 76 28 76;k! o 26 50 5;k! l 4 42 42 80 42;k! l 4 42 58 68 58
    stationery.punched|타공 종이|Punched paper|m|T b 18 8 66 84 5;k! o 29 22 4;k! o 29 50 4;k! o 29 78 4;k! l 3.5 42 28 74 28;k! l 3.5 42 44 74 44;k! l 3.5 42 60 74 60;k! l 3.5 42 76 62 76
    stationery.folder|파일 폴더|Folder|m|T b 8 18 40 24 7;T b 8 28 84 58 9;k! l 3 8 42 92 42
    stationery.inkbottle|잉크병|Ink bottle|c|choco b 34 8 32 20 5;navy b 16 26 68 64 14;cream b 28 46 44 28 4;navy! t 50 60 20 INK
    stationery.penholder|연필꽂이|Pencil cup|m|T l 7 34 50 28 10;T l 7 50 50 50 8;T l 7 68 50 74 10;T p 3 22 40 78 40 74 92 26 92;@paw 50 66 0.42 A=k
    stationery.plane|종이비행기|Paper plane|m|T p 3 8 44 92 10 38 60;T p 3 38 60 92 10 64 88;T p 3 38 60 52 72 38 86
    stationery.correction|수정테이프|Correction tape|m|T b 8 38 70 30 12;k! o 28 53 8;T p 3 72 44 92 52 72 62;k l 3 88 72 20 80
    """#

    static let moneySource = #"""
    money.coin|동전|Coin|m|T o 50 50 40;k! t 50 51 46 ₩
    money.coin.gold|금화|Gold coin|d|yellow o 50 50 40;orange! t 50 52 46 ₩
    money.coin.stack|동전 더미|Coin stack|d|yellow e 50 78 34 12;yellow e 50 66 34 12;yellow e 50 54 34 12;yellow e 50 42 34 12;yellow e 50 30 34 12
    money.bill|지폐|Banknote|m|T b 8 26 84 48 8;k! t 50 51 34 ₩;k! o 20 50 3.5;k! o 80 50 3.5
    money.bundle|돈다발|Bundle of bills|m|T b 18 14 70 40 6;T b 13 22 76 44 6;T b 8 32 84 52 7;k! b 40 32 20 52 2;T! t 50 58 18 ₩;k! o 22 58 3.5;k! o 78 58 3.5
    money.wings|날아가는 돈|Money with wings|m|T e 20 28 14 8 -30;T e 80 28 14 8 30;T p 3 12 48 28 28 36 52;T p 3 88 48 72 28 64 52;T b 22 40 56 40 6;k! t 50 60 26 ₩
    money.wallet|지갑|Wallet|m|T b 8 26 84 60 14;T b 58 44 36 26 10;k! o 72 57 4;k! l 3.5 18 36 72 36
    money.pig|저금통|Piggy bank|d|peach o 50 12 8;pink p 4 26 40 26 22 42 30;pink b 26 74 12 16 4;pink b 62 74 12 16 4;pink e 50 56 38 30;k! b 40 32 20 4 2;rose e 80 56 9 10;k! o 78 53 1.8;k! o 82 58 1.8;k! o 64 50 3.5
    money.cat.pig|고양이 저금통|Cat piggy bank|d|yellow o 50 14 10;@cat.chunhyang 50 54 0.92;k! b 40 29 20 3.5 1.5;@face.smile 50 54 0.92
    money.card|빈 카드|Blank card|m|T b 8 22 84 56 10;k! b 9 34 82 13 0;k! b 18 56 26 7 3
    money.receipt|영수증|Receipt|m|T p 3 20 8 80 8 80 92 70 84 60 92 50 84 40 92 30 84 20 92;k! l 4.5 32 26 68 26;k! l 4.5 32 40 68 40;k! l 4.5 32 54 56 54;k! l 5 32 68 68 68
    money.payday|월급날|Payday|m|T b 8 24 84 58 10;k! l 3.5 11 30 50 46 89 30;k! t 50 64 22 월급
    money.rent|월세|Rent|m|T p 5 50 8 92 46 80 46 80 90 20 90 20 46 8 46;k! t 50 62 34 ₩
    money.utility|공과금|Utility bill|m|T p 3 20 8 80 8 80 92 70 84 60 92 50 84 40 92 30 84 20 92;k! p 3 56 16 34 50 48 50 42 78 66 42 52 42
    money.shopbag|쇼핑백|Shopping bag|m|T l 6 36 36 36 22 50 12 64 22 64 36;T p 3 16 32 84 32 90 90 10 90;@paw 50 60 0.5 A=k
    money.cart|장바구니|Shopping cart|m|T o 36 84 7;T o 72 84 7;T l 7 8 16 22 16 30 70 80 70;T p 3 24 28 92 28 84 60 30 60;k! l 3 42 28 44 60;k! l 3 58 28 58 60;k! l 3 74 28 72 60
    money.pricetag|가격표|Price tag|m|T p 5 12 12 52 12 90 50 50 90 12 52;k! o 28 28 6;k! t 52 54 30 ₩
    money.calculator|가계부 계산기|Budget calculator|m|T b 18 8 64 84 11;k! b 26 16 48 22 3;T t 62 27 18 ₩;k! o 34 52 5;k! o 50 52 5;k! o 66 52 5;k! o 34 72 5;k! o 50 72 5;k! o 66 72 5
    money.graph.up|그래프 오름|Graph up|c|w b 8 8 84 84 12;red! l 7 20 74 40 54 54 64 78 30;red! l 7 58 28 80 28 80 50
    money.graph.down|그래프 내림|Graph down|c|w b 8 8 84 84 12;blue! l 7 20 28 40 48 54 38 78 72;blue! l 7 58 74 80 74 80 52
    money.nospend|무지출|No spend day|m|T o 50 50 40;k! t 50 50 26 무지출
    money.nocoin|돈 안 쓰기|Don't spend|m|T o 50 50 40;k! t 50 51 44 ₩;k! l 7 22 22 78 78
    money.bankbook|적금 통장|Savings book|m|T b 16 10 68 80 8;k! l 3.5 16 26 84 26;k! t 50 46 24 적금;k! l 4 30 66 70 66;k! l 4 30 76 58 76
    money.sale|세일|Sale|m|T star 50 50 44 34 14;k! t 50 50 26 SALE
    money.sale.half|반값 세일|Half price|c|red star 50 50 44 34 14;w! t 50 50 30 50%
    money.won|원화 표시|Won sign|m|T t 50 50 92 ₩
    money.gift|선물 지출|Gift spending|m|T q 7 50 24 28 6 26 22;T q 7 26 22 34 28 50 24;T q 7 50 24 72 6 74 22;T q 7 74 22 66 28 50 24;T b 16 44 68 46 7;T b 10 24 80 22 6;k! l 8 50 24 50 90
    money.subscribe|구독|Subscription|m|@todo.repeat 50 50 1 A=T;k! t 50 51 28 ₩
    money.bank|은행|Bank|m|T p 3 50 8 92 34 8 34;T b 18 38 13 38 3;T b 43.5 38 13 38 3;T b 69 38 13 38 3;T b 10 76 80 14 4;k! t 50 25 15 ₩
    money.ledger|가계부|Household ledger|m|@study.book 50 50 1 A=T;k! t 58 36 28 ₩;k! l 3.5 42 60 74 60;k! l 3.5 42 72 74 72
    money.coupon|쿠폰|Coupon|m|T b 8 26 84 48 8;k! o 8 50 7;k! o 92 50 7;k! l 3 66 32 66 38;k! l 3 66 46 66 54;k! l 3 66 62 66 68;k! t 38 50 22 쿠폰
    money.jar|저금 유리병|Savings jar|c|butter b 28 8 44 12 4;w b 18 18 64 72 14;yellow o 36 74 10;yellow o 62 74 10;yellow o 50 58 10;orange! t 36 74 11 ₩;orange! t 62 74 11 ₩;orange! t 50 58 11 ₩
    money.point|포인트|Points|m|T o 50 50 40;k! t 50 51 46 P
    """#
}
