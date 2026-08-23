// Escrow shared renderer + drivers.
//
// One canvas scene — the trading floor: four booths at the corners of the
// canvas, one per cog, around a central ESCROW BOARD. Each booth shows its
// cog, its profile, its free stock as crate clusters (slate ore, wheat
// grain, brown timber), its escrowed stock greyed behind a padlock, a big
// heart count, and its last message as a speech bubble. Gives slide a
// crate stack booth-to-booth. Every live contract pins to the board as a
// sealed scroll with a countdown seal; a settlement unrolls it, opens the
// chest, and flies the escrow to whoever the branch names — a branch that
// hands both escrows to one party burns the scroll on stage.
//
// Fed by three drivers: live /global websocket, live /player websocket,
// and replay (from the game's /replay websocket or the static wasm
// bundle). All state derivation happens server-side / wasm-side; this file
// only draws state objects:
//   {seats:[{name,profile,score,hearts,stock{ORE,GRAIN,TIMBER,HEARTS},
//            escrowed{...},production{...},commission{...},commissionPay,
//            fills,signed,forfeits,say,heard[],notes,pending} ×4 by SEAT],
//    board:[{id,proposer,acceptor,status,lock,ask,due,turnsLeft,cond,
//            then,else,dsl}],
//    recent:[{id,turn,held,branch,payout,cond,transfers[]}],
//    hearts[4], turn, turns, turnsPlayed, phase:"moves|done", gameDone,
//    reason}
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. Seats
  // are red, blue, green, yellow.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var PAPER_DIM = "#b8ac98";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var CRATE = "#c9a46a";
  var CRATE_EDGE = "#6b4c22";
  var HEART = "#e0523a";
  var STRIP = "rgba(242, 232, 216, 0.06)";
  var SCROLL = "#e7dcc6";
  var SCROLL_EDGE = "#8a7247";
  var CHAR = "#3a2a1c";
  var GOODS = ["ORE", "GRAIN", "TIMBER"];
  var GOOD_FILL = {
    ORE: "#8d97a3",
    GRAIN: "#d9b04a",
    TIMBER: CRATE,
    HEARTS: HEART
  };
  var GOOD_EDGE = {
    ORE: "#4d555f",
    GRAIN: "#8a6c1c",
    TIMBER: CRATE_EDGE,
    HEARTS: "#7a2414"
  };
  // Timing of the turn transition: crates slide between booths, scrolls
  // pin and unroll, speech bubbles pop.
  var SLIDE_MS = 900;
  var SETTLE_MS = 2200;
  var FILL_MS = 1400;
  var BUBBLE_HOLD_MS = 6000;
  var COMPACT_W = 640;

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = ["soldier_red_front.png", "soldier_blue_front.png",
      "soldier_green_front.png", "soldier_yellow_front.png",
      "arena_floor.png", "heart_red.png"];
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // A bundle object {ORE:5} rendered as "5 ore" / "5 ore + 12 hearts",
  // always as numerals — never notation.
  function bundleText(bundle) {
    var parts = [];
    ["ORE", "GRAIN", "TIMBER", "HEARTS"].forEach(function (good) {
      var n = (bundle || {})[good] || 0;
      if (n > 0) parts.push(n + " " + good.toLowerCase());
    });
    return parts.length ? parts.join(" + ") : "nothing";
  }

  function bundleTotal(bundle) {
    var total = 0;
    ["ORE", "GRAIN", "TIMBER", "HEARTS"].forEach(function (good) {
      total += (bundle || {})[good] || 0;
    });
    return total;
  }

  // ---- Layout --------------------------------------------------------------

  // Four booths at the corners, the escrow board in the middle. Everything
  // is measured from the board so the scene scales to whatever frame the
  // viewer is embedded in, down to a 360px-wide phone.
  function computeLayout(width, height) {
    var margin = 8;
    var compact = width < COMPACT_W;
    var boardW = Math.max(150, Math.min(width * 0.40, 430));
    var boardH = Math.max(110, Math.min(height * 0.52, 340));
    var board = {
      x: (width - boardW) / 2,
      y: (height - boardH) / 2,
      w: boardW,
      h: boardH
    };
    var boothW = Math.max(84, (width - boardW) / 2 - margin * 2);
    var boothH = Math.max(90, height / 2 - margin * 1.5);
    var booths = [
      { x: margin, y: margin },
      { x: width - margin - boothW, y: margin },
      { x: margin, y: height - margin - boothH },
      { x: width - margin - boothW, y: height - margin - boothH }
    ].map(function (p) {
      return { x: p.x, y: p.y, w: boothW, h: boothH,
        cx: p.x + boothW / 2, cy: p.y + boothH / 2 };
    });
    var size = Math.max(26, Math.min(76, boothW * 0.42, boothH * 0.30));
    return {
      width: width, height: height, compact: compact, margin: margin,
      board: board, booths: booths, size: size, scale: size / 76
    };
  }

  // ---- Drawing -------------------------------------------------------------

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var seats = view.seats || [];
    var now = view.now || Date.now();
    var L = computeLayout(w, h);
    var scale = L.scale;
    var fx = view.effects || {};

    // Floor.
    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.45)";
    ctx.fillRect(0, 0, w, h);

    // Most hearts leads once the floor is settled.
    var best = -Infinity;
    var level = true;
    seats.forEach(function (seat) {
      if ((seat.hearts || 0) > best) best = seat.hearts || 0;
    });
    seats.forEach(function (seat) {
      if ((seat.hearts || 0) !== best) level = false;
    });

    // Booths.
    for (var s = 0; s < 4; s++) {
      var seat = seats[s];
      if (!seat) continue;
      drawBooth(ctx, images, L, s, seat, {
        pending: seat.pending && !view.done,
        leads: view.done && !level && (seat.hearts || 0) === best,
        fillAt: fx.fillAt ? fx.fillAt[s] : null,
        fillHearts: fx.fillHearts ? fx.fillHearts[s] : 0,
        sayAt: fx.sayAt ? fx.sayAt[s] : null,
        say: fx.lastSay ? fx.lastSay[s] : "",
        now: now
      });
    }

    // Gives in flight, booth to booth.
    (fx.gives || []).forEach(function (give) {
      var age = now - give.at;
      if (age > SLIDE_MS) return;
      var t = Math.max(0, age / SLIDE_MS);
      var e = 1 - Math.pow(1 - t, 3);
      var from = L.booths[give.from];
      var to = L.booths[give.to];
      if (!from || !to) return;
      var x = from.cx + (to.cx - from.cx) * e;
      var y = from.cy + (to.cy - from.cy) * e;
      drawCrateCluster(ctx, x, y, give.n, scale, GOOD_FILL[give.good],
        GOOD_EDGE[give.good], true);
    });

    // The escrow board.
    drawBoard(ctx, L, view, scale, fx, now);
  }

  function drawBooth(ctx, images, L, index, seat, opts) {
    var box = L.booths[index];
    var size = L.size;
    var scale = L.scale;
    var color = seatColor(index);
    var sprite = images["soldier_" + color + "_front.png"];

    ctx.save();
    ctx.fillStyle = STRIP;
    roundRect(ctx, box.x, box.y, box.w, box.h, 8 * scale);
    ctx.fill();
    ctx.restore();

    var top = box.y + 6 * scale;
    // Profile tag (dropped when the frame is narrow) or LEADS.
    if (opts.leads || !L.compact) {
      drawTag(ctx, box.cx, top + 8 * scale,
        opts.leads ? "LEADS" : (seat.profile || "").toUpperCase(),
        opts.leads ? AMBER : COLOR_HEX[color], scale);
      top += 18 * scale;
    }

    var cogY = top + size * 0.55;
    ctx.save();
    ctx.translate(box.cx, cogY);
    if (sprite && sprite.width) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, -size / 2, -size / 2, size, size);
    } else {
      ctx.fillStyle = COLOR_HEX[color];
      ctx.fillRect(-size / 3, -size / 3, size / 1.5, size / 1.5);
    }
    ctx.restore();

    // Acting halo while the floor waits on this seat.
    if (opts.pending) {
      ctx.save();
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = 3;
      ctx.setLineDash([6, 5]);
      ctx.beginPath();
      ctx.arc(box.cx, cogY, size * 0.58, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    // Alias (spectator side: the policy name) and the heart count.
    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "alphabetic";
    // The alias and the heart count are the two things a booth must never
    // lose: they keep a floor size so the scene stays legible at 360px.
    var nameSize = Math.max(12, 13 * scale);
    var heartSize = Math.max(16, 18 * scale);
    ctx.font = "600 " + Math.round(nameSize) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER;
    ctx.shadowColor = "rgba(0,0,0,0.8)";
    ctx.shadowBlur = 4;
    var nameY = cogY + size * 0.58 + nameSize;
    ctx.fillText(ellipsize(ctx, seat.name || "", box.w * 0.94), box.cx, nameY);
    ctx.font = "700 " + Math.round(heartSize) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = AMBER;
    ctx.fillText((seat.hearts || 0) + " ♥", box.cx, nameY + heartSize + 3);
    ctx.restore();

    // Commission fill pop: "+20 ♥" rising over the booth.
    if (opts.fillAt && opts.now - opts.fillAt < FILL_MS) {
      var t = (opts.now - opts.fillAt) / FILL_MS;
      ctx.save();
      ctx.globalAlpha = 1 - t;
      ctx.font = "700 " + Math.round(15 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = AMBER;
      ctx.textAlign = "center";
      ctx.shadowColor = "rgba(0,0,0,0.9)";
      ctx.shadowBlur = 4;
      ctx.fillText("+" + opts.fillHearts + " ♥", box.cx + size * 0.5,
        nameY - 6 * scale - 22 * scale * t);
      ctx.restore();
    }

    // Stock: one crate cluster per good, plus the escrowed pile behind a
    // padlock. Production/commission tags go at narrow widths.
    var stockTop = nameY + heartSize + 12;
    var rowH = Math.max(15, Math.min(22, (box.y + box.h - stockTop) / 3));
    var stock = seat.stock || {};
    var escrowed = seat.escrowed || {};
    for (var g = 0; g < GOODS.length; g++) {
      drawStockRow(ctx, box.x + 6 * scale, stockTop + g * rowH,
        box.w - 12 * scale, rowH, GOODS[g], stock[GOODS[g]] || 0,
        escrowed[GOODS[g]] || 0, scale);
    }
    if (!L.compact) {
      var tagY = stockTop + 3 * rowH + 9 * scale;
      if (tagY < box.y + box.h - 4) {
        ctx.save();
        ctx.font = "600 " + Math.round(9 * scale) +
          "px 'rajdhani', system-ui, sans-serif";
        ctx.fillStyle = GHOST;
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillText(ellipsize(ctx,
          "makes " + bundleText(seat.production) + " · " +
          bundleText(seat.commission) + " → " + (seat.commissionPay || 0) +
          " ♥", box.w - 8), box.cx, tagY);
        ctx.restore();
      }
    }

    // Speech bubble above the booth.
    if (opts.say) {
      var sayAge = typeof opts.sayAt === "number" ? opts.now - opts.sayAt :
        BUBBLE_HOLD_MS;
      var alpha = sayAge < BUBBLE_HOLD_MS ? 1 :
        Math.max(0.4, 1 - (sayAge - BUBBLE_HOLD_MS) / 4000);
      drawBubble(ctx, box.cx, cogY - size * 0.55, opts.say,
        Math.max(120, box.w * 1.1), scale, alpha);
    }
  }

  // One good's row: a crate cluster, the free count as a numeral, and the
  // escrowed count greyed behind a padlock glyph.
  function drawStockRow(ctx, x, y, w, h, good, free, locked, scale) {
    var cs = Math.max(5, Math.min(9 * scale, h * 0.42));
    ctx.save();
    var shown = Math.min(6, Math.max(free > 0 ? 1 : 0, Math.ceil(free / 3)));
    for (var i = 0; i < shown; i++) {
      drawCrate(ctx, x + i * (cs + 1), y + h / 2 - cs / 2, cs - 1,
        GOOD_FILL[good], GOOD_EDGE[good]);
    }
    ctx.font = "700 " + Math.round(Math.max(11, 12 * scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "left";
    ctx.textBaseline = "middle";
    ctx.fillStyle = free > 0 ? PAPER : GHOST;
    ctx.shadowColor = "rgba(0,0,0,0.9)";
    ctx.shadowBlur = 3;
    var numX = x + 6 * (cs + 1) + 4;
    ctx.fillText(String(free), numX, y + h / 2);
    var numW = ctx.measureText(String(free)).width;
    ctx.font = "600 " + Math.round(Math.max(8, 8.5 * scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = GHOST;
    ctx.fillText(good.toLowerCase(), numX + numW + 4, y + h / 2 + 1);
    if (locked > 0) {
      var lockX = x + w - 2;
      ctx.textAlign = "right";
      ctx.fillStyle = PAPER_DIM;
      ctx.font = "600 " + Math.round(Math.max(9, 10 * scale)) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillText("🔒" + locked, lockX, y + h / 2);
    }
    ctx.restore();
  }

  // A compact crate cluster: up to 12 crates in rows of 4, quantity tagged.
  function drawCrateCluster(ctx, cx, cy, units, scale, fill, edge, tag) {
    var n = Math.min(12, Math.max(1, Math.ceil(units / 2)));
    var cs = 9 * scale;
    var cols = Math.min(4, n);
    var rows = Math.ceil(n / cols);
    var x0 = cx - cols * cs / 2;
    var y0 = cy + rows * cs / 2 - cs;
    ctx.save();
    for (var i = 0; i < n; i++) {
      var cxi = x0 + (i % cols) * cs;
      var cyi = y0 - Math.floor(i / cols) * cs;
      drawCrate(ctx, cxi, cyi, cs - 1, fill, edge);
    }
    if (tag) {
      ctx.font = "700 " + Math.round(13 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "bottom";
      ctx.fillStyle = PAPER;
      ctx.shadowColor = "rgba(0,0,0,0.9)";
      ctx.shadowBlur = 3;
      ctx.fillText(String(units), cx, y0 - rows * cs + cs - 3 * scale);
    }
    ctx.restore();
  }

  function drawCrate(ctx, x, y, s, fill, edge) {
    ctx.fillStyle = fill;
    ctx.fillRect(x, y, s, s);
    ctx.strokeStyle = edge;
    ctx.lineWidth = 1;
    ctx.strokeRect(x + 0.5, y + 0.5, s - 1, s - 1);
    ctx.beginPath();
    ctx.moveTo(x + 1, y + s / 2);
    ctx.lineTo(x + s - 1, y + s / 2);
    ctx.stroke();
  }

  // ---- The escrow board ----------------------------------------------------

  function drawBoard(ctx, L, view, scale, fx, now) {
    var board = L.board;
    var live = view.board || [];
    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.62)";
    roundRect(ctx, board.x, board.y, board.w, board.h, 8 * scale);
    ctx.fill();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.16)";
    ctx.lineWidth = 1;
    ctx.stroke();

    ctx.font = "700 " + Math.round(Math.max(10, 11 * scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    ctx.fillText("ESCROW BOARD", board.x + board.w / 2, board.y + 5);
    ctx.restore();

    // Soonest due first, so the scroll about to fire is the one on top.
    var sorted = live.slice().sort(function (a, b) {
      if ((a.turnsLeft || 0) !== (b.turnsLeft || 0)) {
        return (a.turnsLeft || 0) - (b.turnsLeft || 0);
      }
      return String(a.id).localeCompare(String(b.id));
    });

    var top = board.y + Math.max(19, 20 * scale);
    var listH = board.h - Math.max(25, 26 * scale);
    // At 360px the board collapses to a single stack: only the soonest-due
    // scroll is expanded, with a count badge for the rest.
    var maxScrolls = L.compact ? 1 : Math.max(1,
      Math.min(4, Math.floor(listH / (34 * scale))));
    var shown = sorted.slice(0, maxScrolls);
    var rowH = shown.length ? Math.min(listH / shown.length, 62 * scale) :
      listH;

    if (!sorted.length) {
      ctx.save();
      ctx.font = "600 " + Math.round(Math.max(10, 11 * scale)) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = GHOST;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText("no live contracts", board.x + board.w / 2,
        board.y + board.h / 2);
      ctx.restore();
    }

    shown.forEach(function (contract, i) {
      drawScroll(ctx, board.x + 6 * scale, top + i * rowH,
        board.w - 12 * scale, rowH - 4 * scale, contract, scale, L.compact);
    });

    if (sorted.length > shown.length) {
      ctx.save();
      ctx.font = "700 " + Math.round(10 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = INK;
      var badge = "+" + (sorted.length - shown.length) + " MORE";
      var bw = ctx.measureText(badge).width + 10 * scale;
      ctx.fillStyle = AMBER;
      roundRect(ctx, board.x + board.w - bw - 6 * scale,
        board.y + board.h - 16 * scale, bw, 13 * scale, 3 * scale);
      ctx.fill();
      ctx.fillStyle = INK;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(badge, board.x + board.w - bw / 2 - 6 * scale,
        board.y + board.h - 9 * scale);
      ctx.restore();
    }

    // Settlement overlay: the chest opens, the crates fly, and a forfeit
    // branch chars the scroll on stage.
    var settle = fx.settle;
    if (settle && now - settle.at < SETTLE_MS) {
      drawSettlement(ctx, L, settle, (now - settle.at) / SETTLE_MS, scale);
    }
  }

  function drawScroll(ctx, x, y, w, h, contract, scale, compact) {
    var signed = contract.status === "signed";
    ctx.save();
    ctx.fillStyle = SCROLL;
    ctx.strokeStyle = SCROLL_EDGE;
    ctx.lineWidth = 1.5;
    if (!signed) ctx.setLineDash([5, 4]);
    roundRect(ctx, x, y, w, h, 4 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.setLineDash([]);

    // Party colour chips.
    ctx.fillStyle = COLOR_HEX[seatColor(contract.proposer || 0)];
    ctx.fillRect(x + 4 * scale, y + 4 * scale, 6 * scale, 6 * scale);
    ctx.fillStyle = COLOR_HEX[seatColor(contract.acceptor || 0)];
    ctx.fillRect(x + 12 * scale, y + 4 * scale, 6 * scale, 6 * scale);

    ctx.fillStyle = INK;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.font = "700 " + Math.round(Math.max(11, 11 * scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillText(contract.id, x + 22 * scale, y + 3 * scale);

    // Countdown seal: wax when signed, an open ring when merely offered.
    var left = contract.turnsLeft || 0;
    var seal = left > 0 ? "DUE IN " + left : "DUE NOW";
    ctx.font = "700 " + Math.round(Math.max(9, 9 * scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "right";
    var sw = ctx.measureText(seal).width + 8 * scale;
    ctx.fillStyle = signed ? "#a33a2a" : "rgba(138, 114, 71, 0.25)";
    roundRect(ctx, x + w - sw - 3 * scale, y + 3 * scale, sw, 12 * scale,
      6 * scale);
    ctx.fill();
    ctx.fillStyle = signed ? PAPER : INK;
    ctx.textBaseline = "middle";
    ctx.fillText(seal, x + w - 7 * scale, y + 9 * scale);

    // The trade itself, in words and numerals.
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillStyle = INK;
    ctx.font = "600 " + Math.round(Math.max(10, 10 * scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    var line = bundleText(contract.lock) + "  ⇄  " + bundleText(contract.ask);
    ctx.fillText(ellipsize(ctx, line, w - 8 * scale), x + 5 * scale,
      y + 16 * scale);
    if (!compact && h > 34 * scale) {
      ctx.fillStyle = "#5a4a34";
      ctx.font = "600 " + Math.round(9 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillText(ellipsize(ctx, "IF " + (contract.cond || "ALWAYS") +
        " → " + (contract["then"] || "") + " · ELSE " +
        (contract["else"] || ""), w - 8 * scale), x + 5 * scale,
        y + 28 * scale);
    }
    ctx.restore();
  }

  function drawSettlement(ctx, L, settle, t, scale) {
    var board = L.board;
    var cx = board.x + board.w / 2;
    var cy = board.y + board.h / 2;
    var burn = settle.payout === "PROPOSER" || settle.payout === "ACCEPTOR";
    var w = Math.min(board.w - 20 * scale, 240 * scale);
    var h = 46 * scale;
    ctx.save();
    ctx.globalAlpha = Math.max(0, 1 - Math.pow(t, 3));
    // The scroll unrolls, then chars away when the escrow forfeits.
    ctx.fillStyle = burn ? mix(SCROLL, CHAR, Math.min(1, t * 1.6)) : SCROLL;
    ctx.strokeStyle = burn ? "#7a2414" : AMBER;
    ctx.lineWidth = 2;
    var unroll = Math.min(1, t * 3);
    roundRect(ctx, cx - w / 2, cy - h / 2, w * unroll, h, 4 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = burn ? PAPER : INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = "700 " + Math.round(12 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    var head = settle.id + " · " + (settle.branch === "horizon" ? "HORIZON" :
      (settle.held ? "TRUE" : "FALSE")) + " → " + settle.payout;
    ctx.fillText(ellipsize(ctx, head, w - 10 * scale), cx, cy - 9 * scale);
    ctx.font = "600 " + Math.round(9.5 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = burn ? PAPER_DIM : "#5a4a34";
    var condText = ellipsize(ctx, settle.cond || "ALWAYS", w - 10 * scale);
    ctx.fillText(condText, cx, cy + 7 * scale);
    if (burn) {
      // A struck-through clause: the loophole that just fired.
      var cw = ctx.measureText(condText).width;
      ctx.strokeStyle = "#e0523a";
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(cx - cw / 2, cy + 7 * scale);
      ctx.lineTo(cx + cw / 2, cy + 7 * scale);
      ctx.stroke();
    }
    ctx.restore();

    // The escrow flies to whoever the branch named.
    (settle.legs || []).forEach(function (leg, i) {
      var target = L.booths[leg.to];
      if (!target) return;
      var e = 1 - Math.pow(1 - Math.min(1, t * 1.4), 2);
      var offset = (i - ((settle.legs.length - 1) / 2)) * 16 * scale;
      var x = cx + offset + (target.cx - cx - offset) * e;
      var y = cy + (target.cy - cy) * e;
      drawCrateCluster(ctx, x, y, leg.n, scale, GOOD_FILL[leg.good],
        GOOD_EDGE[leg.good], true);
    });
  }

  function mix(a, b, t) {
    var ca = hexToRgb(a);
    var cb = hexToRgb(b);
    return "rgb(" + Math.round(ca[0] + (cb[0] - ca[0]) * t) + "," +
      Math.round(ca[1] + (cb[1] - ca[1]) * t) + "," +
      Math.round(ca[2] + (cb[2] - ca[2]) * t) + ")";
  }

  function drawTag(ctx, x, y, text, accent, scale) {
    ctx.save();
    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    var label = (text || "").toUpperCase();
    var pad = 5 * scale;
    var bw = ctx.measureText(label).width + pad * 2;
    var bh = 15 * scale;
    ctx.fillStyle = "rgba(242, 232, 216, 0.95)";
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2;
    roundRect(ctx, x - bw / 2, y - bh / 2, bw, bh, 4 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(label, x, y + scale);
    ctx.restore();
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = text.split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = ellipsize(ctx, lines[lines.length - 1] + "…",
        maxWidth);
    }
    return lines.map(function (l) { return ellipsize(ctx, l, maxWidth); });
  }

  function drawBubble(ctx, x, bottom, text, maxW, scale, alpha) {
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.font = Math.round(10.5 * scale) +
      "px -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif";
    var pad = 6 * scale;
    var lineH = 13 * scale;
    var lines = wrapLines(ctx, text, maxW - pad * 2, 3);
    var bw = 0;
    lines.forEach(function (l) { bw = Math.max(bw, ctx.measureText(l).width); });
    bw += pad * 2;
    var bh = lines.length * lineH + pad * 2 - 2;
    var y = bottom - bh - 6 * scale;
    ctx.shadowColor = "rgba(0,0,0,0.6)";
    ctx.shadowBlur = 5;
    ctx.fillStyle = PAPER;
    roundRect(ctx, x - bw / 2, y, bw, bh, 5 * scale);
    ctx.fill();
    ctx.shadowColor = "transparent";
    ctx.beginPath();
    ctx.moveTo(x - 5 * scale, y + bh);
    ctx.lineTo(x, y + bh + 6 * scale);
    ctx.lineTo(x + 5 * scale, y + bh);
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = INK;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    lines.forEach(function (l, i) {
      ctx.fillText(l, x - bw / 2 + pad, y + pad + i * lineH);
    });
    ctx.restore();
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous table names ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  // Feed lines are legible sentences, never notation: "Sprocket offers C7 to
  // Ratchet — 5 ore for 12 hearts, due turn 8".
  function describeEvent(event, nameMap, ctx) {
    function name(i) {
      return clampName(nameMap.seat(i));
    }
    switch (event.kind) {
      case "start":
        return "The floor opens — three goods, four cogs, every contract " +
          "pre-funded.";
      case "turn":
        return "Booths restocked. Hearts on the floor: " +
          (event.seats || []).map(function (s) {
            return (s.stock && s.stock.HEARTS) || 0;
          }).join(" / ") + ".";
      case "move":
        var bits = [];
        if (event.offer) bits.push("drafts a contract");
        if ((event.signs || []).length) {
          bits.push("moves on " + event.signs.join(", "));
        }
        if ((event.gives || []).length) bits.push("hands goods over");
        if (!bits.length) bits.push("passes");
        return name(event.seat) + " " + bits.join(", ") +
          (event.scripted ? " ·" : "");
      case "offer":
        return name(event.seat) + " offers " + event.id + " to " +
          name(event.target) + " — " + bundleText(event.lock) + " for " +
          bundleText(event.ask) + ", due turn " + event.due +
          (event.cond && event.cond !== "ALWAYS" ?
            ", if " + event.cond.toLowerCase() : "");
      case "sign":
        return event.ok ?
          name(event.seat) + " signs " + event.id + " — escrow sealed" :
          name(event.seat) + " cannot sign " + event.id +
            (event.text ? " (" + event.text + ")" : "");
      case "give":
        return event.ok ?
          name(event.seat) + " gives " + name(event.to) + " " + event.n +
            " " + String(event.good).toLowerCase() :
          name(event.seat) + " fails to give" +
            (event.text ? " (" + event.text + ")" : "");
      case "reject":
        return name(event.seat) + "'s draft was refused — " +
          (event.text || "invalid contract");
      case "expire":
        return event.id + " expires unsigned — the stake goes back to " +
          name(event.seat);
      case "settle":
        var legs = (event.transfers || []).map(function (leg) {
          return name(leg.to) + " +" + leg.n + " " +
            String(leg.good).toLowerCase();
        });
        var verdict = event.branch === "horizon" ? "horizon closure" :
          (event.cond || "ALWAYS") + "? " + (event.held ? "YES" : "NO");
        return event.id + " settles: " + verdict + " → " + event.payout +
          (legs.length ? ". " + legs.join(", ") : "");
      case "fill":
        return name(event.seat) + " fills " + event.n + " commission" +
          (event.n === 1 ? "" : "s") + " +" + event.hearts + " hearts";
      case "end":
        var top = ctx.leader;
        return "Final — " + (top ? top.name + " " + top.hearts + " hearts" :
          "no hearts") +
          (event.text === "deadline" ? " — episode deadline." : ".");
      default: return JSON.stringify(event);
    }
  }

  function blockHead(block) {
    return block < 0 ? "SETUP" : "TURN " + block;
  }

  // Renders the full transcript grouped into one section per turn.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var html = "";
    var lastBlock = null;
    var ctx = { leader: null };
    var lastNotes = {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.turn;
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block) + "</div>";
        lastBlock = block;
      }
      if (event.kind === "turn") {
        var best = null;
        (event.seats || []).forEach(function (s, si) {
          var h = (s.stock && s.stock.HEARTS) || 0;
          if (!best || h > best.hearts) {
            best = { hearts: h, name: clampName(nameMap.seat(si)) };
          }
        });
        ctx.leader = best;
      }
      var text = describeEvent(event, nameMap, ctx);
      var cls = "feed-line feed-" + event.kind +
        (typeof event.seat === "number" && event.seat >= 0 ?
          " seat" + (event.seat % COLORS.length) : "") +
        (event.kind === "end" ? " feed-rwin" : "") +
        (event.kind === "settle" ? " feed-settle" : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' + escapeHtml(text) + "</div>";
      if (event.kind === "move" && event.say) {
        html += '<div class="feed-line feed-say' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + " says: " +
            nameMap.text(event.say)) + "</div>";
      }
      // Notes: dim, only when the seat's notes changed.
      if (event.kind === "move" && event.text &&
          event.text !== lastNotes[event.seat]) {
        lastNotes[event.seat] = event.text;
        html += '<div class="feed-line feed-notes' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + " notes: " +
            nameMap.text(event.text)) + "</div>";
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return String(text).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects:
  // when the turn opened, each booth's last message, the gives in flight,
  // the commission pops, and the settlement now on stage.
  function makeEffects() {
    var seen = 0;
    var turnAt = null;
    var sayAt = [null, null, null, null];
    var lastSay = ["", "", "", ""];
    var fillAt = [null, null, null, null];
    var fillHearts = [0, 0, 0, 0];
    var gives = [];
    var settle = null;
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only
      // the newest event gets to animate.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "turn") {
            turnAt = animate ? now : null;
            gives = [];
          } else if (event.kind === "move") {
            if (event.say) {
              lastSay[event.seat] = event.say;
              sayAt[event.seat] = animate ? now : null;
            }
          } else if (event.kind === "give" && event.ok && animate) {
            gives.push({ from: event.seat, to: event.to, n: event.n,
              good: event.good, at: now });
            if (gives.length > 6) gives.shift();
          } else if (event.kind === "fill") {
            fillAt[event.seat] = animate ? now : null;
            fillHearts[event.seat] = event.hearts;
          } else if (event.kind === "settle" && animate) {
            settle = { id: event.id, payout: event.payout, held: event.held,
              branch: event.branch, cond: event.cond,
              legs: event.transfers || [], at: now };
          }
        }
      },
      reset: function () {
        seen = 0; turnAt = null;
        sayAt = [null, null, null, null];
        lastSay = ["", "", "", ""];
        fillAt = [null, null, null, null];
        fillHearts = [0, 0, 0, 0];
        gives = [];
        settle = null;
      },
      view: function () {
        return { effects: { turnAt: turnAt, sayAt: sayAt.slice(),
          lastSay: lastSay.slice(), fillAt: fillAt.slice(),
          fillHearts: fillHearts.slice(), gives: gives.slice(),
          settle: settle } };
      }
    };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  function matchHeader(state, config) {
    var parts = [];
    if (state) {
      var total = state.turns || (config && config.turns) || 0;
      parts.push("TURN " + (state.turn || 0) + (total ? " / " + total : ""));
      if (state.gameDone || state.done) {
        parts.push("FINAL");
      } else if (state.seats) {
        var waiting = state.seats.filter(function (s) { return s.pending; });
        parts.push(waiting.length ? "WAITING ON " + waiting.length :
          "DECISIONS IN");
      }
    }
    return parts.join(" · ");
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      var stock = seat.stock || {};
      var escrowed = seat.escrowed || {};
      var locked = bundleTotal(escrowed);
      html += '<div class="plate ' + seatColor(index) + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (seat.pending && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-score">' + escapeHtml(String(seat.hearts || 0)) +
        "</span>" +
        '<span class="plate-label">' + escapeHtml(seat.profile || "") +
        "</span>" +
        '<span class="plate-stock">' + (stock.ORE || 0) + "/" +
        (stock.GRAIN || 0) + "/" + (stock.TIMBER || 0) + "</span>" +
        (locked ? '<span class="plate-escrow">' + locked +
          " locked</span>" : "") +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function reasonLine(results) {
    switch (results.reason) {
      case "deadline":
        return "episode deadline: scored on " + (results.turns || 0) +
          " of " + (results.maxTurns || results.turns || 0) + " turns";
      default: return "";
    }
  }

  // Final standings overlay: verdict up top, ranked rows below.
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var hearts = results.hearts || results.scores || [];
    var fills = results.fills || [];
    var signed = results.signed || [];
    var forfeits = results.forfeits || [];
    var profiles = results.profiles || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) { return (hearts[b] || 0) - (hearts[a] || 0); });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (hearts[i] || 0) === (hearts[topIndex] || 0);
    });
    var verdictColor = !level && topIndex >= 0 ? seatColor(topIndex) : "";
    var verdict = !level && topIndex >= 0 ?
      escapeHtml(names[topIndex]) + " — MOST HEARTS AT HORIZON" : "ALL LEVEL";
    var reason = reasonLine(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.turns || 0) + " TURN" +
      ((results.turns || 0) === 1 ? "" : "S") + " · " +
      escapeHtml(String(results.heartsMinted || 0)) + " HEARTS MINTED</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">profile</span>' +
      '<span class="end-head">hearts</span>' +
      '<span class="end-head">fills</span>' +
      '<span class="end-head">signed</span>' +
      '<span class="end-head">forfeits</span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell(escapeHtml(profiles[i] || "")) +
        cell(escapeHtml(String(hearts[i] || 0))) +
        cell(escapeHtml(String(fills[i] || 0))) +
        cell(escapeHtml(String(signed[i] || 0))) +
        cell(escapeHtml(String(forfeits[i] || 0)));
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = applyNames(state.seats, nameMap);
    view.board = state.board || [];
    view.recent = state.recent || [];
    view.turn = state.turn || 0;
    view.turns = state.turns || 0;
    view.turnsPlayed = state.turnsPlayed || 0;
    view.phase = state.phase || "";
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  // A player frame ({seat:{...}, board:[...]}) becomes a four-seat state
  // with the own booth filled in so the same scene draws.
  function playerFrameToState(data) {
    if (data.seats) return data;
    var seats = [];
    for (var i = 0; i < 4; i++) {
      seats.push({ name: "Seat " + i, hearts: 0, stock: {}, escrowed: {} });
    }
    if (typeof data.slot === "number" && data.seat) {
      seats[data.slot] = Object.assign({}, data.seat, { name: data.name });
    }
    return {
      seats: seats, board: data.board || [], recent: [],
      turn: data.turn, turns: data.turns, turnsPlayed: data.turnsPlayed,
      phase: data.done ? "done" : "moves", gameDone: data.done,
      reason: data.reason, events: []
    };
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen,
    //           assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var nameMap = makeNameMap([], null);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = playerFrameToState(data);
            if (latest) {
              nameMap = makeNameMap(seatNames(latest), latest.policyNames);
              effects.absorb(latest.events || []);
              if (options.feed) {
                renderFeed(options.feed, latest.events || [], nameMap,
                  undefined);
              }
              if (options.clock) {
                options.clock.textContent = matchHeader(latest, latest);
              }
              updateScorebug(options.scorebug, latest, nameMap);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      (function frame() {
        if (latest) {
          var view = stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone)
          });
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // Scrubber: a click/drag-to-seek track with one span per turn, a marker
  // per move and settlement, and the end (taller).
  function buildScrub(container, events, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.turn;
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0 && r % 4 === 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    events.forEach(function (event, i) {
      var kind = event.kind;
      if (kind !== "move" && kind !== "settle" && kind !== "end") return;
      var marker = document.createElement("div");
      marker.className = "beat-marker" +
        (kind === "move" ? " seat" + (event.seat % COLORS.length) : "") +
        (kind === "settle" ? " rwin" : "") +
        (kind === "end" ? " death" : "");
      marker.style.left = ((i + 1) / events.length * 100) + "%";
      container.appendChild(marker);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, assetBase, payload}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var index = 0;
    var playing = true;
    var lastStep = 0;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return states[Math.min(index, states.length - 1)] ||
          { seats: [], phase: "", turn: 0 };
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) renderFeed(options.feed, events, nameMap, index);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent = matchHeader(currentState(), config);
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is currently looking at: a turn opening
        // gets read, a settlement gets watched, a plain move less so.
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = shown && shown.kind === "turn" ? 1100 :
          shown && shown.kind === "settle" ? 1600 :
          shown && shown.kind === "offer" ? 900 :
          shown && shown.kind === "move" ? (shown.say ? 900 : 420) :
          shown && shown.kind === "end" ? 1500 :
          600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var view = stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0
        });
        renderer.draw(view);
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  window.EscrowRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle
  };
})();
