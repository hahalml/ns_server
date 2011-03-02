// This is new-style computed cells. Those have dynamic set of
// dependencies and have more lightweight, functional style. They are
// also lazy, which means that cell value is not (re)computed if
// nothing demands that value. Which happens when nothing is
// subscribed to this cell and it doesn't have dependent cells.
//
// Main guy here is Cell.compute. See it's comments. See also
// testCompute test in cells-test.js.


Cell.id = (function () {
  var counter = 1;
  return function (cell) {
    if (cell.__identity) {
      return cell.__identity;
    }
    return (cell.__identity = counter++);
  };
})();

FlexiFormulaCell = mkClass(Cell, {
  emptyFormula: function () {},
  initialize: function ($super, flexiFormula, isEager) {
    $super();

    var recalculate = $m(this, 'recalculate'),
        currentSources = this.currentSources = {};

    this.formula = function () {
      var rvPair = flexiFormula.call(this),
          newValue = rvPair[0],
          dependencies = rvPair[1];

      for (var i in currentSources) {
        if (dependencies[i]) {
          continue;
        } else {
          var pair = currentSources[i];
          pair[0].dependenciesSlot.unsubscribe(pair[1]);
          delete currentSources[i];
        }
      }

      for (var j in dependencies) {
        if (j in currentSources) {
          continue;
        } else {
          var cell = dependencies[j],
              slave = cell.dependenciesSlot.subscribeWithSlave(recalculate);

          currentSources[j] = [cell, slave];
        }
      }

      return newValue;
    };

    this.formulaContext = {self: this};
    if (isEager) {
      this.effectiveFormula = this.formula;
      this.recalculate();
    } else {
      this.effectiveFormula = this.emptyFormula;
      this.setupDemandObserving();
    }
  },
  setupDemandObserving: function () {
    var demand = {},
        self = this;
    _.each(
      {
        changed: self.changedSlot,
        'undefined': self.undefinedSlot,
        dependencies: self.dependenciesSlot
      },
      function (slot, name) {
        slot.__demandChanged = function (newDemand) {
          demand[name] = newDemand;
          react();
        };
      }
    );
    function react() {
      var haveDemand = demand.dependencies || demand.changed || demand['undefined'];

      if (!haveDemand) {
        self.detach();
      } else {
        self.attachBack();
      }
    }
  },
  needsRefresh: function (newValue) {
    if (this.value === undefined) {
      return true;
    }
    if (newValue instanceof Future) {
      return false;
    }
    return this.isValuesDiffer(this.value, newValue);
  },
  attachBack: function () {
    if (this.effectiveFormula === this.formula) {
      return;
    }

    this.effectiveFormula = this.formula;

    // NOTE: this has side-effect of updating formula dependencies and
    // subscribing to them back
    var newValue = this.effectiveFormula.call(this.mkFormulaContext());
    // we don't want to recalculate values that involve futures
    if (this.needsRefresh(newValue)) {
      this.recalculate();
    }
  },
  detach: function () {
    var currentSources = this.currentSources;
    for (var id in currentSources) {
      if (id) {
        var pair = currentSources[id];
        pair[0].dependenciesSlot.unsubscribe(pair[1]);
        delete currentSources[id];
      }
    }
    this.effectiveFormula = this.emptyFormula;
    this.setValue(this.value);  // this cancels any in-progress
                                // futures
  },
  setSources: function () {
    throw new Error("unsupported!");
  },
  mkFormulaContext: function () {
    return this.formulaContext;
  },
  getSourceCells: function () {
    var rv = [],
        sources = this.currentSources;
    for (var id in sources) {
      if (id) {
        rv.push(sources[id][0]);
      }
    }
    return rv;
  }
});

FlexiFormulaCell.noValueMarker = (function () {
  try {
    throw {};
  } catch (e) {
    return e;
  }
})();

FlexiFormulaCell.makeComputeFormula = function (formula) {
  var dependencies,
      noValue = FlexiFormulaCell.noValueMarker;

  function getValue(cell) {
    var id = Cell.id(cell);
    if (!dependencies[id]) {
      dependencies[id] = cell;
    }
    return cell.value;
  }

  function need(cell) {
    var v = getValue(cell);
    if (v === undefined) {
      throw noValue;
    }
    return v;
  }

  getValue.need = need;

  return function () {
    dependencies = {};
    var newValue;
    try {
      newValue = formula.call(this, getValue);
    } catch (e) {
      if (e === noValue) {
        newValue = undefined;
      } else {
        throw e;
      }
    }
    var deps = dependencies;
    dependencies = null;
    return [newValue, deps];
  };
};

// Creates cell that is computed by running formula. This function is
// passed V argument. Which is a function that gets values of other
// cells. It is necessary to obtain dependent cell values via that
// function, so that all dependencies are recorded. Then if any of
// (dynamic) dependencies change formula is recomputed. Which may
// produce (apart from new value) new set of dependencies.
//
// V also has a useful helper: V.need which is just as V extracts
// values from cells. But it differs from V in that undefined values
// are never returned. Special exception is raised instead to signal
// that formula value is undefined.
Cell.compute = function (formula) {
  var _FlexiFormulaCell = arguments[1] || FlexiFormulaCell,
      f = FlexiFormulaCell.makeComputeFormula(formula);

  return new _FlexiFormulaCell(f);
};

Cell.computeEager = function (formula) {
  var _FlexiFormulaCell = arguments[1] || FlexiFormulaCell,
      f = FlexiFormulaCell.makeComputeFormula(formula);

  return new _FlexiFormulaCell(f, true);
};