/*
 * Copyright © 2023 Brinvex (dev@brinvex.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.brinvex.dbmanager.internal.common;

import java.io.Serializable;
import java.util.Objects;
import java.util.StringJoiner;

public class OsCmdResult implements Serializable {

    private final String out;

    private final String err;

    public OsCmdResult(String out, String err) {
        this.out = out;
        this.err = err;
    }

    public String getOut() {
        return out;
    }

    public String getErr() {
        return err;
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (o == null || getClass() != o.getClass()) return false;
        OsCmdResult that = (OsCmdResult) o;
        return Objects.equals(out, that.out) && Objects.equals(err, that.err);
    }

    @Override
    public int hashCode() {
        return Objects.hash(out, err);
    }

    @Override
    public String toString() {
        return new StringJoiner(", ", OsCmdResult.class.getSimpleName() + "[", "]")
                .add("out='" + out + "'")
                .add("err='" + err + "'")
                .toString();
    }
}
